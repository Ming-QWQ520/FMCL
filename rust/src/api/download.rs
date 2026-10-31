//! 并发下载引擎。
//!
//! 特性：
//! - 可配置并发度（信号量控制）
//! - 指数退避自动重试
//! - SHA1 / 大小双重校验，已存在且校验通过的文件自动跳过（幂等重跑）
//! - 临时文件 + 原子重命名，避免半成品文件
//! - 聚合进度事件流（Rust 侧 100ms 节流，避免 Dart 层回调风暴）
//! - 会话级取消
//!
//! 通过桥接事件发射器回传进度（100ms 节流，Dart 侧还原为 Stream）。

use crate::util::cancel::CANCEL_REGISTRY;
use anyhow::Result;
use std::path::Path;
use std::sync::atomic::{AtomicI32, AtomicI64, Ordering};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::sync::Semaphore;

/// 单个下载任务描述
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DownloadItem {
    pub url: String,
    pub save_path: String,
    /// 期望 SHA1（小写十六进制），None 表示不校验
    pub expected_sha1: Option<String>,
    /// 期望字节数，None 表示不校验
    pub expected_size: Option<i64>,
    /// 备用 URL 列表（主 URL 失败时依次尝试）
    pub alt_urls: Vec<String>,
}

/// 下载进度事件
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgressEvent {
    /// "progress" | "file_done" | "file_failed" | "done" | "cancelled"
    pub kind: String,
    pub finished_files: i32,
    pub failed_files: i32,
    pub total_files: i32,
    /// 已下载字节（本次会话累计）
    pub downloaded_bytes: i64,
    /// 本次会话需要下载的总字节
    pub total_bytes: i64,
    /// 实时速度 字节/秒
    pub speed_bps: i64,
    /// 当前完成的文件路径（kind 为 file_done/file_failed 时有效）
    pub current_file: Option<String>,
    pub error_message: Option<String>,
}

/// 单文件下载结果
#[derive(Debug, Clone)]
pub struct DownloadFileResult {
    pub save_path: String,
    pub success: bool,
    pub error: Option<String>,
}

/// 创建下载会话，返回 session id（Dart 侧保存以便取消）
pub fn create_download_session() -> String {
    let id = new_session_id();
    CANCEL_REGISTRY.create(&id);
    id
}

/// 取消一个下载会话
pub fn cancel_download(session_id: String) {
    CANCEL_REGISTRY.cancel(&session_id);
}

/// 释放会话句柄
pub fn dispose_download_session(session_id: String) {
    CANCEL_REGISTRY.dispose(&session_id);
}

/// 执行批量下载。
///
/// `concurrency`：并发连接数（建议 8~64）。
/// `user_agent`：可选自定义 UA（BMCLAPI 建议使用可识别的 UA）。
///
/// 结果通过事件流回传：file_done / file_failed / done / cancelled。
/// Dart 侧根据 failed_files 计数判断整体成败。
pub async fn download_batch(
    items: Vec<DownloadItem>,
    concurrency: i32,
    session_id: String,
    user_agent: Option<String>,
    em: &crate::bridge::Emitter,
) {
    let cancelled = CANCEL_REGISTRY.handle(&session_id);
    let client = match build_client(user_agent) {
        Ok(c) => c,
        Err(e) => {
            em.send(&DownloadProgressEvent {
                kind: "file_failed".into(),
                finished_files: 0,
                failed_files: items.len() as i32,
                total_files: items.len() as i32,
                downloaded_bytes: 0,
                total_bytes: 0,
                speed_bps: 0,
                current_file: None,
                error_message: Some(format!("初始化 HTTP 客户端失败: {e}")),
            });
            return;
        }
    };
    let semaphore = Arc::new(Semaphore::new(concurrency.max(1) as usize));

    let total_files = items.len() as i32;
    let finished = Arc::new(AtomicI32::new(0));
    let failed = Arc::new(AtomicI32::new(0));
    let bytes_done = Arc::new(AtomicI64::new(0));
    let total_bytes = Arc::new(AtomicI64::new(
        items.iter().map(|i| i.expected_size.unwrap_or(0)).sum(),
    ));
    let speed_bps = Arc::new(AtomicI64::new(0));

    // 聚合进度上报任务（100ms 节流）
    let reporter = {
        let finished = finished.clone();
        let failed = failed.clone();
        let bytes_done = bytes_done.clone();
        let total_bytes = total_bytes.clone();
        let speed_bps = speed_bps.clone();
        let cancelled = cancelled.clone();
        let reporter_sink = em.clone();
        tokio::spawn(async move {
            let mut last_bytes = 0i64;
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                let now_bytes = bytes_done.load(Ordering::Relaxed);
                speed_bps.store((now_bytes - last_bytes) * 10, Ordering::Relaxed);
                last_bytes = now_bytes;
                let is_cancelled = cancelled.load(Ordering::Relaxed);
                reporter_sink.send(&DownloadProgressEvent {
                    kind: if is_cancelled { "cancelled" } else { "progress" }.into(),
                    finished_files: finished.load(Ordering::Relaxed),
                    failed_files: failed.load(Ordering::Relaxed),
                    total_files,
                    downloaded_bytes: now_bytes,
                    total_bytes: total_bytes.load(Ordering::Relaxed),
                    speed_bps: speed_bps.load(Ordering::Relaxed),
                    current_file: None,
                    error_message: None,
                });
                if is_cancelled {
                    break;
                }
            }
        })
    };

    // 并发执行所有文件
    let mut tasks = Vec::with_capacity(items.len());
    for item in items {
        let client = client.clone();
        let semaphore = semaphore.clone();
        let cancelled = cancelled.clone();
        let bytes_done = bytes_done.clone();
        tasks.push(tokio::spawn(async move {
            let permit = semaphore.acquire_owned().await;
            let result = if cancelled.load(Ordering::Relaxed) {
                DownloadFileResult {
                    save_path: item.save_path.clone(),
                    success: false,
                    error: Some("已取消".into()),
                }
            } else {
                run_one(&client, &item, &bytes_done).await
            };
            drop(permit);
            (item, result)
        }));
    }

    for task in tasks {
        match task.await {
            Ok((item, result)) => {
                let success = result.success;
                if success {
                    finished.fetch_add(1, Ordering::Relaxed);
                } else {
                    failed.fetch_add(1, Ordering::Relaxed);
                }
                em.send(&DownloadProgressEvent {
                    kind: if success { "file_done" } else { "file_failed" }.into(),
                    finished_files: finished.load(Ordering::Relaxed),
                    failed_files: failed.load(Ordering::Relaxed),
                    total_files,
                    downloaded_bytes: bytes_done.load(Ordering::Relaxed),
                    total_bytes: total_bytes.load(Ordering::Relaxed),
                    speed_bps: speed_bps.load(Ordering::Relaxed),
                    current_file: Some(item.save_path.clone()),
                    error_message: result.error.clone(),
                });
            }
            Err(e) => {
                failed.fetch_add(1, Ordering::Relaxed);
                em.send(&DownloadProgressEvent {
                    kind: "file_failed".into(),
                    finished_files: finished.load(Ordering::Relaxed),
                    failed_files: failed.load(Ordering::Relaxed),
                    total_files,
                    downloaded_bytes: bytes_done.load(Ordering::Relaxed),
                    total_bytes: total_bytes.load(Ordering::Relaxed),
                    speed_bps: speed_bps.load(Ordering::Relaxed),
                    current_file: None,
                    error_message: Some(format!("任务异常: {e}")),
                });
            }
        }
    }

    reporter.abort();
    let is_cancelled = cancelled.load(Ordering::Relaxed);
    em.send(&DownloadProgressEvent {
        kind: if is_cancelled { "cancelled" } else { "done" }.into(),
        finished_files: finished.load(Ordering::Relaxed),
        failed_files: failed.load(Ordering::Relaxed),
        total_files,
        downloaded_bytes: bytes_done.load(Ordering::Relaxed),
        total_bytes: total_bytes.load(Ordering::Relaxed),
        speed_bps: 0,
        current_file: None,
        error_message: None,
    });
}

/// 下载单个文件（含重试与校验）
pub(crate) async fn run_one(
    client: &reqwest::Client,
    item: &DownloadItem,
    bytes_done: &Arc<AtomicI64>,
) -> DownloadFileResult {
    // 本地已有且校验通过 → 跳过下载
    if std::fs::metadata(&item.save_path).is_ok() && verify_existing(item).unwrap_or(false) {
        return DownloadFileResult {
            save_path: item.save_path.clone(),
            success: true,
            error: None,
        };
    }

    let save = Path::new(&item.save_path);
    let tmp = save.with_extension("fmclpart");
    if let Some(parent) = save.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return fail(&item.save_path, format!("创建目录失败: {e}"));
        }
    }

    const MAX_RETRIES: usize = 3;
    let mut candidates: Vec<String> = Vec::with_capacity(1 + item.alt_urls.len());
    candidates.push(item.url.clone());
    candidates.extend(item.alt_urls.iter().cloned());
    let mut last_err = String::new();
    for candidate in &candidates {
        let mut attempt_item = item.clone();
        attempt_item.url = candidate.clone();
        attempt_item.alt_urls = vec![];
        for attempt in 0..MAX_RETRIES {
            if attempt > 0 {
                tokio::time::sleep(std::time::Duration::from_millis(600 * attempt as u64)).await;
            }
            match try_download_once(client, &attempt_item, &tmp, bytes_done).await {
                Ok(()) => {
                    if let Err(msg) = validate(&tmp, &attempt_item) {
                        last_err = msg;
                        continue;
                    }
                    if let Err(e) = rename_atomic(&tmp, save) {
                        return fail(&item.save_path, format!("落盘失败: {e}"));
                    }
                    return DownloadFileResult {
                        save_path: item.save_path.clone(),
                        success: true,
                        error: None,
                    };
                }
                Err(e) => {
                    last_err = e.to_string();
                    let _ = tokio::fs::remove_file(&tmp).await;
                }
            }
        }
    }
    fail(&item.save_path, format!("重试 {MAX_RETRIES} 次后失败: {last_err}"))
}

async fn try_download_once(
    client: &reqwest::Client,
    item: &DownloadItem,
    tmp: &Path,
    bytes_done: &Arc<AtomicI64>,
) -> Result<()> {
    let resp = client.get(&item.url).send().await?.error_for_status()?;
    let mut stream = resp.bytes_stream();
    let mut file = tokio::fs::File::create(tmp).await?;
    use futures_util::StreamExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        bytes_done.fetch_add(chunk.len() as i64, Ordering::Relaxed);
    }
    file.flush().await?;
    file.sync_all().await.ok();
    Ok(())
}

/// 校验临时文件的大小与 SHA1
fn validate(tmp: &Path, item: &DownloadItem) -> Result<(), String> {
    if let Some(expect_size) = item.expected_size {
        let actual = std::fs::metadata(tmp).map(|m| m.len() as i64).unwrap_or(-1);
        if actual != expect_size {
            return Err(format!("大小不匹配: 期望 {expect_size}, 实际 {actual}"));
        }
    }
    if let Some(sha) = &item.expected_sha1 {
        let actual = crate::api::hash::file_sha1(tmp.to_string_lossy().into_owned())
            .map_err(|e| format!("SHA1 计算失败: {e}"))?;
        if !actual.eq_ignore_ascii_case(sha) {
            return Err(format!("SHA1 不匹配: 期望 {sha}, 实际 {actual}"));
        }
    }
    Ok(())
}

fn rename_atomic(from: &Path, to: &Path) -> Result<()> {
    // Windows 上 rename 不允许覆盖已存在目标，先移除
    if to.exists() {
        std::fs::remove_file(to)?;
    }
    std::fs::rename(from, to)?;
    Ok(())
}

fn verify_existing(item: &DownloadItem) -> Result<bool> {
    // 文件不存在一律视为未完成（即使无校验元数据）
    if !Path::new(&item.save_path).exists() {
        return Ok(false);
    }
    if item.expected_sha1.is_none() && item.expected_size.is_none() {
        return Ok(true);
    }
    if let Some(size) = item.expected_size {
        let actual = std::fs::metadata(&item.save_path).map(|m| m.len() as i64)?;
        if actual != size {
            return Ok(false);
        }
    }
    if let Some(sha) = &item.expected_sha1 {
        let actual = crate::api::hash::file_sha1(item.save_path.clone())?;
        if !actual.eq_ignore_ascii_case(sha) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn build_client(user_agent: Option<String>) -> Result<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .read_timeout(std::time::Duration::from_secs(60))
        .pool_max_idle_per_host(16)
        .timeout(std::time::Duration::from_secs(600))
        .user_agent(
            user_agent.unwrap_or_else(|| "FMCL/1.0 (github.com/Ming-QWQ520/FMCL)".into()),
        );
    Ok(builder.build()?)
}

fn fail(path: &str, err: String) -> DownloadFileResult {
    DownloadFileResult { save_path: path.into(), success: false, error: Some(err) }
}

/// 轻量级会话 ID（不引入额外依赖）
fn new_session_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("dl_{nanos:x}_{}", std::process::id())
}
