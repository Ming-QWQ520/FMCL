//! 游戏子进程管理。
//!
//! - 启动 Minecraft 进程并实时回传 stdout/stderr 行事件
//! - Windows 下对非 UTF-8 输出自动按 GBK 解码（简体中文控制台编码）
//! - 查询退出码 / 终止进程
//! - 完整日志落盘由 Dart 侧基于事件流自行完成（职责分离）

use anyhow::{anyhow, Result};
use once_cell::sync::Lazy;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::Command;
use tokio::sync::Mutex;

/// 进程输出事件
#[derive(Debug, Clone, Deserialize)]
pub struct ProcessOutputEvent {
    pub pid: i32,
    /// "stdout" | "stderr"
    pub stream: String,
    pub line: String,
}

/// 进程退出信息
#[derive(Debug, Clone, Deserialize)]
pub struct ProcessExitInfo {
    pub pid: i32,
    pub exit_code: i32,
    /// 是否正常退出（code == 0）
    pub success: bool,
}

/// 进程启动配置
#[derive(Debug, Clone, Deserialize)]
pub struct ProcessSpawnConfig {
    /// 可执行文件路径（java/javaw）
    pub program: String,
    pub args: Vec<String>,
    pub working_dir: String,
    /// 附加环境变量（在继承父进程环境之上）
    pub env: HashMap<String, String>,
}

struct ChildHandle {
    child: Arc<Mutex<tokio::process::Child>>,
    /// 尚未被 attach_output_stream 认领的输出流
    pending_stdout: Option<tokio::process::ChildStdout>,
    pending_stderr: Option<tokio::process::ChildStderr>,
    /// 输出流是否已被认领
    attached: bool,
}

static NEXT_HANDLE: AtomicI32 = AtomicI32::new(1);
static CHILDREN: Lazy<std::sync::Mutex<HashMap<i32, ChildHandle>>> =
    Lazy::new(|| std::sync::Mutex::new(HashMap::new()));

/// 启动游戏进程。
///
/// 返回内部句柄 id（用于 attachOutputStream / waitProcess / killProcess）。
pub async fn spawn_game_process(config: ProcessSpawnConfig) -> Result<i32> {
    let handle_id = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);

    let mut cmd = Command::new(&config.program);
    cmd.args(&config.args)
        .current_dir(&config.working_dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .stdin(std::process::Stdio::null())
        .kill_on_drop(false);
    for (k, v) in &config.env {
        cmd.env(k, v);
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| anyhow!("启动进程失败 ({}): {e}", config.program))?;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    CHILDREN.lock().unwrap().insert(
        handle_id,
        ChildHandle {
            child: Arc::new(Mutex::new(child)),
            pending_stdout: stdout,
            pending_stderr: stderr,
            attached: false,
        },
    );

    Ok(handle_id)
}

/// 认领进程输出流并回传事件（同一 handle 只能 attach 一次）。
/// Dart 侧拿到返回的 Stream 自行监听。
pub fn attach_output_stream(
    handle_id: i32,
    sink: crate::frb_generated::StreamSink<ProcessOutputEvent>,
) -> Result<()> {
    let mut registry = CHILDREN.lock().unwrap();
    let handle = registry
        .get_mut(&handle_id)
        .ok_or_else(|| anyhow!("进程句柄不存在: {handle_id}"))?;
    anyhow::ensure!(!handle.attached, "进程输出流已被认领: {handle_id}");
    handle.attached = true;
    let stdout = handle.pending_stdout.take();
    let stderr = handle.pending_stderr.take();
    drop(registry);

    if let Some(out) = stdout {
        spawn_pump(out, handle_id, "stdout".into(), sink.clone());
    }
    if let Some(err) = stderr {
        spawn_pump(err, handle_id, "stderr".into(), sink.clone());
    }
    Ok(())
}

fn spawn_pump<R: AsyncRead + Unpin + Send + 'static>(
    reader: R,
    handle_id: i32,
    stream_name: String,
    sink: crate::frb_generated::StreamSink<ProcessOutputEvent>,
) {
    tokio::spawn(async move {
        let mut reader = BufReader::new(reader);
        let mut buf: Vec<u8> = Vec::with_capacity(512);
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let line = decode_line(&buf);
                    let _ = sink.add(ProcessOutputEvent {
                        pid: handle_id,
                        stream: stream_name.clone(),
                        line,
                    });
                }
            }
        }
    });
}

/// 按行解码原始字节：优先 UTF-8，失败时 Windows 按 GBK、其他平台 lossy
fn decode_line(raw: &[u8]) -> String {
    match std::str::from_utf8(raw) {
        Ok(s) => s.trim_end_matches(['\n', '\r']).to_string(),
        Err(_) => {
            #[cfg(windows)]
            {
                let (decoded, _, _) = encoding_rs::GBK.decode(raw);
                decoded.trim_end_matches(['\n', '\r']).to_string()
            }
            #[cfg(not(windows))]
            {
                String::from_utf8_lossy(raw).trim_end_matches(['\n', '\r']).to_string()
            }
        }
    }
}

/// 等待进程退出（同一 handle 仅应 wait 一次）
pub async fn wait_game_process(handle_id: i32) -> Result<ProcessExitInfo> {
    let child_arc = CHILDREN
        .lock()
        .unwrap()
        .get(&handle_id)
        .map(|h| h.child.clone())
        .ok_or_else(|| anyhow!("进程句柄不存在: {handle_id}"))?;

    let mut guard = child_arc.lock().await;
    let status = guard
        .wait()
        .await
        .map_err(|e| anyhow!("等待进程退出失败: {e}"))?;
    drop(guard);
    CHILDREN.lock().unwrap().remove(&handle_id);

    let code = status.code().unwrap_or(-1);
    Ok(ProcessExitInfo {
        pid: handle_id,
        exit_code: code,
        success: status.success(),
    })
}

/// 终止进程
pub async fn kill_game_process(handle_id: i32) -> Result<bool> {
    let child_arc = CHILDREN
        .lock()
        .unwrap()
        .get(&handle_id)
        .map(|h| h.child.clone());
    match child_arc {
        Some(child) => {
            let mut c = child.lock().await;
            Ok(c.start_kill().is_ok())
        }
        None => Ok(false),
    }
}

/// 列出仍在运行的句柄 id
pub fn list_running_processes() -> Vec<i32> {
    CHILDREN.lock().unwrap().keys().copied().collect()
}
