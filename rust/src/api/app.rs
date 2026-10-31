//! 应用初始化与日志 API（Flutter 侧的通信入口）。
//!
//! Flutter 启动后第一步调用 `init_app`：解析便携目录、初始化日志、
//! 返回全部路径。日志流通过 `subscribe_app_logs` 实时推送到 UI。

use crate::core::logging::LogEntry;
use crate::core::paths;
use anyhow::Result;
use std::path::PathBuf;

/// 应用路径信息（一次性返回给 Flutter）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub app_version: String,
    pub exe_dir: String,
    pub fmcl_root: String,
    pub default_game_dir: String,
    pub logs_dir: String,
    pub game_logs_dir: String,
    pub crash_reports_dir: String,
    pub authlib_injector_dir: String,
    pub cache_dir: String,
    pub java_dir: String,
    pub os_name: String,
    pub arch: String,
}

/// 初始化应用（幂等）：解析目录、创建子目录、初始化日志系统。
pub fn init_app() -> Result<AppInfo> {
    let p = paths::resolve();

    // 日志系统初始化（失败不阻断启动）
    if let Err(e) = crate::core::logging::init(p.logs_dir.clone()) {
        eprintln!("日志系统初始化失败: {e}");
    }
    crate::log_info!(
        "Main",
        "FMCL 0.1.0 启动 | exe: {} | FMCL 根: {} | 默认游戏目录: {}",
        p.exe_dir.display(),
        p.fmcl_root.display(),
        p.default_game_dir.display()
    );

    Ok(AppInfo {
        app_version: "0.1.0".into(),
        exe_dir: p.exe_dir.to_string_lossy().into_owned(),
        fmcl_root: p.fmcl_root.to_string_lossy().into_owned(),
        default_game_dir: p.default_game_dir.to_string_lossy().into_owned(),
        logs_dir: p.logs_dir.to_string_lossy().into_owned(),
        game_logs_dir: p.game_logs_dir.to_string_lossy().into_owned(),
        crash_reports_dir: p.crash_reports_dir.to_string_lossy().into_owned(),
        authlib_injector_dir: p.authlib_injector_dir.to_string_lossy().into_owned(),
        cache_dir: p.cache_dir.to_string_lossy().into_owned(),
        java_dir: p.java_dir.to_string_lossy().into_owned(),
        os_name: std::env::consts::OS.into(),
        arch: std::env::consts::ARCH.into(),
    })
}

/// 订阅启动器实时日志流（UI 日志页）。
///
/// 日志由 `bridge::fmcl_init` 以 `app_log` 事件持续推送，
/// 此处仅为语义占位：确认日志系统已初始化。
pub fn subscribe_app_logs() -> Result<()> {
    crate::core::logging::subscribe()
        .ok_or_else(|| anyhow::anyhow!("日志系统尚未初始化"))?;
    Ok(())
}

/// Dart 侧日志/全局错误转发落盘（写入 latest.log，与 Rust 日志同格式）。
pub fn log_app(level: String, module: String, message: String) -> Result<()> {
    crate::core::logging::log(&level, &module, &message);
    Ok(())
}

/// 读取 latest.log 末尾若干行
pub fn read_recent_logs(max_lines: i32) -> Result<Vec<LogEntry>> {
    let p = paths::paths();
    Ok(crate::core::logging::read_tail(
        &p.logs_dir,
        max_lines.max(1) as usize,
    ))
}

/// 读取指定日志目录下全部日志文件名（latest.log + 轮转 + app-*.log）
pub fn list_log_files() -> Result<Vec<LogFileMeta>> {
    let p = paths::paths();
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&p.logs_dir) {
        for e in rd.flatten() {
            let path = e.path();
            if !path.is_file() {
                continue;
            }
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let meta = std::fs::metadata(&path).ok();
            out.push(LogFileMeta {
                name,
                path: path.to_string_lossy().into_owned(),
                size_bytes: meta.as_ref().map(|m| m.len() as i64).unwrap_or(0),
                modified_ms: meta
                    .as_ref()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0),
            });
        }
    }
    out.sort_by_key(|f| std::cmp::Reverse(f.modified_ms));
    Ok(out)
}

/// 日志文件元信息
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogFileMeta {
    pub name: String,
    pub path: String,
    pub size_bytes: i64,
    pub modified_ms: i64,
}

/// 读取某个日志文件的内容（末尾 max_lines 行）
pub fn read_log_file(path: String, max_lines: i32) -> Result<String> {
    let content = std::fs::read_to_string(&path)?;
    if max_lines <= 0 {
        return Ok(content);
    }
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(max_lines as usize);
    Ok(lines[start..].join("\n"))
}

/// 用系统文件管理器打开目录/文件
pub fn open_path(path: String) -> Result<()> {
    let p = PathBuf::from(&path);
    anyhow::ensure!(p.exists(), "路径不存在: {path}");
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(&p)
            .spawn()
            .map_err(|e| anyhow::anyhow!("打开失败: {e}"))?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open").arg(&p).spawn()?;
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open").arg(&p).spawn()?;
    }
    Ok(())
}
