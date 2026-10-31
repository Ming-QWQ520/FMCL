//! 便携目录系统（对齐 PCL2 便携模式）。
//!
//! Windows 下所有启动器数据固定在 **exe 所在目录\FMCL\** 下：
//! ```text
//! <exeDir>/
//!  ├─ FMCL/
//!  │   ├─ logs/                    启动器完整日志（latest.log + 按天归档 + 轮转）
//!  │   │   ├─ game/                每次游戏启动的完整输出镜像
//!  │   │   └─ crash-reports/       启动器崩溃报告
//!  │   ├─ lib/authlib-injector/    外置登录 authlib-injector.jar
//!  │   ├─ cache/                   启动器缓存（版本清单等）
//!  │   └─ java/                    自动安装的 Java 运行时
//!  └─ .minecraft/                  游戏目录（便携默认）
//! ```
//! exe 目录不可写（如 Program Files）时自动回退到系统应用支持目录。

use once_cell::sync::OnceCell;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct AppPaths {
    /// exe 所在目录（桌面端）
    pub exe_dir: PathBuf,
    /// FMCL 数据根目录
    pub fmcl_root: PathBuf,
    /// 默认游戏目录（exe 所在目录\.minecraft）
    pub default_game_dir: PathBuf,
    /// 日志目录
    pub logs_dir: PathBuf,
    /// 游戏输出镜像目录
    pub game_logs_dir: PathBuf,
    /// 崩溃报告目录
    pub crash_reports_dir: PathBuf,
    /// 启动器库目录（authlib-injector 等）
    pub lib_dir: PathBuf,
    /// authlib-injector 目录
    pub authlib_injector_dir: PathBuf,
    /// 缓存目录
    pub cache_dir: PathBuf,
    /// 自动安装 Java 目录
    pub java_dir: PathBuf,
}

impl AppPaths {
    /// authlib-injector jar 完整路径（FMCL\lib\authlib-injector\authlib-injector.jar）
    pub fn authlib_injector_jar(&self) -> PathBuf {
        self.authlib_injector_dir
            .join("authlib-injector")
            .join("authlib-injector.jar")
    }
}

static PATHS: OnceCell<AppPaths> = OnceCell::new();

/// 目录是否可写（探测文件法）
pub fn is_writable(dir: &std::path::Path) -> bool {
    let probe = dir.join(".fmcl_write_probe");
    match std::fs::write(&probe, b"ok") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// 系统应用支持目录（回退用）
fn system_support_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Ok(appdata) = std::env::var("APPDATA") {
            return PathBuf::from(appdata).join("FMCL");
        }
        if let Ok(profile) = std::env::var("USERPROFILE") {
            return PathBuf::from(profile).join("AppData").join("Roaming").join("FMCL");
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join("Library").join("Application Support").join("FMCL");
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(".local").join("share").join("FMCL");
        }
    }
    std::env::temp_dir().join("FMCL")
}

/// 解析并创建全部目录（进程内幂等）
pub fn resolve() -> &'static AppPaths {
    PATHS.get_or_init(|| {
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("."));

        let base_candidate = exe_dir.join("FMCL");
        let fmcl_root = if is_writable(&exe_dir) {
            let _ = std::fs::create_dir_all(&base_candidate);
            base_candidate
        } else {
            let fallback = system_support_dir();
            let _ = std::fs::create_dir_all(&fallback);
            fallback
        };

        let default_game_dir = exe_dir.join(".minecraft");
        let logs_dir = fmcl_root.join("logs");
        let game_logs_dir = logs_dir.join("game");
        let crash_reports_dir = logs_dir.join("crash-reports");
        let lib_dir = fmcl_root.join("lib");
        let authlib_injector_dir = lib_dir.join("authlib-injector");
        let cache_dir = fmcl_root.join("cache");
        let java_dir = fmcl_root.join("java");

        for d in [
            &logs_dir,
            &game_logs_dir,
            &crash_reports_dir,
            &authlib_injector_dir,
            &cache_dir,
            &java_dir,
        ] {
            let _ = std::fs::create_dir_all(d);
        }

        AppPaths {
            exe_dir,
            fmcl_root,
            default_game_dir,
            logs_dir,
            game_logs_dir,
            crash_reports_dir,
            lib_dir,
            authlib_injector_dir,
            cache_dir,
            java_dir,
        }
    })
}

/// 全局访问（resolve 之后必然存在）
pub fn paths() -> &'static AppPaths {
    resolve()
}
