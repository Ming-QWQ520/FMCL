//! 启动器完整日志系统。
//!
//! - 输出至 `<FMCL 根>/logs/latest.log`（本次运行）并轮转旧日志
//! - 同时写入 `<FMCL 根>/logs/app-YYYYMMDD.log`（按天归档）
//! - 全局广播通道：UI 日志页可实时订阅（Flutter 仅消费）
//!
//! 由 `api::app::init_app` 在启动时初始化一次。

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use tokio::sync::broadcast;

/// 一条日志事件（对 UI 暴露）
#[derive(Debug, Clone, serde::Serialize)]
pub struct LogEntry {
    /// ISO 风格本地时间 "2026-10-31 12:00:00.123"
    pub time: String,
    /// INFO / WARN / ERROR / DEBUG
    pub level: String,
    /// 模块名（如 "Launch" / "Dirs"）
    pub module: String,
    pub message: String,
}

static LOGGER: OnceLock<Logger> = OnceLock::new();

pub struct Logger {
    dir: PathBuf,
    file: Mutex<Option<File>>,
    tx: broadcast::Sender<LogEntry>,
}

pub fn init(dir: PathBuf) -> Result<&'static Logger, String> {
    if let Some(l) = LOGGER.get() {
        return Ok(l);
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建日志目录失败: {e}"))?;
    rotate_old_logs(&dir);

    let (tx, _) = broadcast::channel(4096);
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("latest.log"))
        .map_err(|e| format!("打开日志文件失败: {e}"))?;

    let logger = Logger {
        dir,
        file: Mutex::new(Some(file)),
        tx,
    };
    let _ = LOGGER.set(logger);
    Ok(LOGGER.get().unwrap())
}

/// 轮转：保留最近 10 份 latest-*.log
fn rotate_old_logs(dir: &PathBuf) {
    let stamp = now_string().replace([' ', ':'], "-");
    let target = dir.join(format!("latest-{stamp}.log"));
    let src = dir.join("latest.log");
    if src.exists() {
        let _ = std::fs::rename(&src, &target);
    }
    // 清理多余的旧轮转文件（保留 10 个）
    let mut olds: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .map(|n| n.to_string_lossy().starts_with("latest-"))
                .unwrap_or(false)
        })
        .collect();
    olds.sort();
    while olds.len() > 10 {
        let _ = std::fs::remove_file(olds.remove(0));
    }
}

fn now_string() -> String {
    
    chrono_now()
}

/// 无 chrono 依赖的本地时间格式化（秒 + 毫秒）
pub fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let total_secs = dur.as_secs() as i64;
    let millis = dur.subsec_millis();
    let (y, mo, d, h, mi, s) = civil_from_unix(total_secs);
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}.{millis:03}")
}

/// Unix 秒 → 公历时间（UTC；启动器按本地习惯展示，偏差可接受）
/// 使用 Proleptic Gregorian 算法（与 chrono 相同的公式）。
pub fn civil_from_unix(secs: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86_400);
    let secs_of_day = secs.rem_euclid(86_400);
    let h = (secs_of_day / 3600) as u32;
    let mi = ((secs_of_day % 3600) / 60) as u32;
    let s = (secs_of_day % 60) as u32;
    // Howard Hinnant 的 civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d, h, mi, s)
}

/// 写入一条日志（落盘 + 广播）
pub fn log(level: &str, module: &str, message: &str) {
    let Some(logger) = LOGGER.get() else {
        return;
    };
    let entry = LogEntry {
        time: chrono_now(),
        level: level.to_string(),
        module: module.to_string(),
        message: message.to_string(),
    };
    let line = format!(
        "[{}] [{}] [{}] {}\n",
        entry.time, entry.level, entry.module, entry.message
    );
    if let Ok(mut guard) = logger.file.lock() {
        if let Some(f) = guard.as_mut() {
            let _ = f.write_all(line.as_bytes());
            let _ = f.flush();
        }
    }
    // 按天归档（失败静默）
    let day_file = logger.dir.join(format!("app-{}.log", &entry.time[..10].replace('-', "")));
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&day_file) {
        let _ = f.write_all(line.as_bytes());
    }
    let _ = logger.tx.send(entry);
}

#[macro_export]
macro_rules! app_log {
    ($level:expr, $module:expr, $($arg:tt)*) => {
        $crate::core::logging::log($level, $module, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! log_info {
    ($module:expr, $($arg:tt)*) => {
        $crate::app_log!("INFO", $module, $($arg)*)
    };
}

#[macro_export]
macro_rules! log_warn {
    ($module:expr, $($arg:tt)*) => {
        $crate::app_log!("WARN", $module, $($arg)*)
    };
}

#[macro_export]
macro_rules! log_error {
    ($module:expr, $($arg:tt)*) => {
        $crate::app_log!("ERROR", $module, $($arg)*)
    };
}

#[macro_export]
macro_rules! log_debug {
    ($module:expr, $($arg:tt)*) => {
        $crate::app_log!("DEBUG", $module, $($arg)*)
    };
}

impl Logger {
    pub fn subscribe(&self) -> broadcast::Receiver<LogEntry> {
        self.tx.subscribe()
    }
}

/// 全局获取日志订阅器（init 之后可用）
pub fn subscribe() -> Option<broadcast::Receiver<LogEntry>> {
    LOGGER.get().map(|l| l.subscribe())
}

/// 读取 latest.log 末尾若干行（用于 UI 首屏展示）
pub fn read_tail(dir: &std::path::Path, max_lines: usize) -> Vec<LogEntry> {
    let path = dir.join("latest.log");
    let Ok(content) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(max_lines);
    lines[start..]
        .iter()
        .filter_map(|l| parse_log_line(l))
        .collect()
}

/// 解析一条日志行（容错：不匹配时整行归 message）
pub fn parse_log_line(line: &str) -> Option<LogEntry> {
    let trimmed = line.trim_end();
    if trimmed.is_empty() {
        return None;
    }
    // [time] [LEVEL] [Module] message
    if trimmed.starts_with('[') {
        let mut parts = trimmed.splitn(4, "][");
        let t1 = parts.next()?.trim_start_matches('[').to_string();
        if t1.len() >= 19 && t1.contains('-') {
            let level = parts
                .next()
                .unwrap_or("INFO")
                .trim()
                .to_string();
            let module = parts
                .next()
                .unwrap_or("App")
                .trim()
                .to_string();
            let message = parts.next().unwrap_or("").to_string();
            return Some(LogEntry {
                time: t1,
                level,
                module,
                message,
            });
        }
    }
    Some(LogEntry {
        time: String::new(),
        level: "INFO".into(),
        module: "Game".into(),
        message: trimmed.to_string(),
    })
}
