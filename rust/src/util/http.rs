//! 内部 HTTP 助手（不在 FRB 暴露范围内）。

use crate::api::download::{run_one, DownloadFileResult, DownloadItem};
use anyhow::Result;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

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

/// 供 install 等内部模块复用的 HTTP 客户端
pub fn build_public_client() -> Result<reqwest::Client> {
    build_client(None)
}

/// 批量下载核心（无事件流依赖），供 install 管线复用。
///
/// 返回 (成功数, 失败数)。已存在且校验通过的文件自动跳过。
pub async fn download_all(
    items: &[DownloadItem],
    concurrency: usize,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
    user_agent: Option<String>,
    mut on_file_done: impl FnMut(bool, &DownloadItem, Option<String>) + Send,
) -> (i32, i32) {
    let client = match build_client(user_agent) {
        Ok(c) => c,
        Err(_) => return (0, items.len() as i32),
    };
    let semaphore = Arc::new(tokio::sync::Semaphore::new(concurrency.max(1)));
    let mut finished = 0i32;
    let mut failed = 0i32;

    let mut tasks = Vec::with_capacity(items.len());
    for item in items {
        let client = client.clone();
        let semaphore = semaphore.clone();
        let cancelled = cancelled.clone();
        let item = item.clone();
        tasks.push(tokio::spawn(async move {
            let permit = semaphore.acquire_owned().await;
            let result = if cancelled.load(Ordering::Relaxed) {
                DownloadFileResult {
                    save_path: item.save_path.clone(),
                    success: false,
                    error: Some("已取消".into()),
                }
            } else {
                run_one(&client, &item, &Arc::new(AtomicI64::new(0))).await
            };
            drop(permit);
            (item, result)
        }));
    }
    for task in tasks {
        match task.await {
            Ok((item, result)) => {
                if result.success {
                    finished += 1;
                } else {
                    failed += 1;
                }
                on_file_done(result.success, &item, result.error);
            }
            Err(_) => failed += 1,
        }
    }
    (finished, failed)
}
