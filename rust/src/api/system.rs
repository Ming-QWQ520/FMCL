//! 系统信息查询。

use serde::Deserialize;

/// 操作系统类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum OsKind {
    Windows,
    Linux,
    MacOs,
    Android,
    Other,
}

/// CPU / 内存等架构信息
#[derive(Debug, Clone, Deserialize)]
pub struct SystemInfo {
    pub os: OsKind,
    /// 例如 "x86_64" / "aarch64"
    pub arch: String,
    /// 物理内存总量（MiB）
    pub total_memory_mb: i64,
    /// 可用内存（MiB）
    pub available_memory_mb: i64,
    /// 逻辑 CPU 数量
    pub cpu_count: i32,
}

pub fn system_info() -> SystemInfo {
    let os = match std::env::consts::OS {
        "windows" => OsKind::Windows,
        "linux" => OsKind::Linux,
        "macos" => OsKind::MacOs,
        "android" => OsKind::Android,
        _ => OsKind::Other,
    };
    let arch = normalize_arch(std::env::consts::ARCH).to_string();

    let mut sys = sysinfo::System::new();
    sys.refresh_memory();
    let total = sys.total_memory() as i64 / (1024 * 1024);
    let available = sys.available_memory() as i64 / (1024 * 1024);
    let cpu_count = sysinfo::System::physical_core_count().unwrap_or(0) as i32;

    SystemInfo {
        os,
        arch,
        total_memory_mb: total.max(1),
        available_memory_mb: available.max(0),
        cpu_count,
    }
}

fn normalize_arch(arch: &str) -> &'static str {
    match arch {
        "x86_64" | "x86" => "x86_64",
        "aarch64" => "aarch64",
        "arm" => "arm32",
        "riscv64" => "riscv64",
        _ => "unknown",
    }
}
