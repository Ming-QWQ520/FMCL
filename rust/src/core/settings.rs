//! 设置存储（Rust 全量接管，Flutter 只读写展示）。
//!
//! - 全局设置：`<FMCL 根>/config.json`
//! - 每版本设置：`<gameDir>/versions/<id>/fmcl-settings.json`
//! 语义与字段与 PCL2「设置 / 版本设置」一致：版本字段缺省 = 跟随全局。

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// 全局设置
// ---------------------------------------------------------------------------

/// 启动器全局设置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    // ---------- 外观 ----------
    /// 0=跟随系统 1=浅色 2=深色
    #[serde(default)]
    pub theme_mode: i32,
    /// 自定义背景图绝对路径（空=无）
    #[serde(default)]
    pub background_image_path: String,
    /// 背景不透明度 0~100
    #[serde(default = "d45")]
    pub background_opacity: i32,
    /// 背景模糊 0~50
    #[serde(default)]
    pub background_blur: i32,

    // ---------- 目录 ----------
    /// 游戏根目录（空 = exe 所在目录\.minecraft）
    #[serde(default)]
    pub game_directory: String,
    /// 额外 Java 搜索目录
    #[serde(default)]
    pub java_search_paths: Vec<String>,

    // ---------- 启动 ----------
    #[serde(default = "d2048")]
    pub max_memory_mb: i32,
    #[serde(default = "d512")]
    pub min_memory_mb: i32,
    #[serde(default)]
    pub jvm_arguments: String,
    #[serde(default)]
    pub game_arguments: String,
    /// 手动指定 Java（空=自动）
    #[serde(default)]
    pub java_path: String,
    /// 启动后行为 0=保持 1=隐藏 2=关闭
    #[serde(default = "d1")]
    pub launcher_behavior: i32,
    /// 进程优先级 0=普通 1=高 2=低
    #[serde(default)]
    pub process_priority: i32,
    /// 启动后自动加入服务器
    #[serde(default)]
    pub server_address: String,
    /// 启动前执行命令
    #[serde(default)]
    pub pre_launch_command: String,
    /// 环境变量（每行 KEY=VALUE）
    #[serde(default)]
    pub launch_environment: Vec<String>,
    /// 包装命令
    #[serde(default)]
    pub wrapper_command: String,
    #[serde(default)]
    pub fullscreen: bool,
    #[serde(default)]
    pub window_width: i32,
    #[serde(default)]
    pub window_height: i32,
    /// 启动器窗口大小记忆
    #[serde(default = "d1120")]
    pub window_launcher_width: i32,
    #[serde(default = "d720")]
    pub window_launcher_height: i32,

    // ---------- 下载 ----------
    /// 0=BMCLAPI 优先（默认，国内友好）1=官方优先
    #[serde(default)]
    pub download_source_index: i32,
    #[serde(default = "dtrue")]
    pub auto_fallback: bool,
    #[serde(default = "d32")]
    pub concurrency: i32,
    #[serde(default = "dtrue")]
    pub verify_files: bool,

    // ---------- 版本管理 ----------
    /// 版本隔离（PCL2 式），默认开启
    #[serde(default = "dtrue")]
    pub version_isolation: bool,
    /// 缺失 Java 自动安装
    #[serde(default = "dtrue")]
    pub auto_install_java: bool,

    // ---------- 状态 ----------
    #[serde(default)]
    pub last_account_id: String,
    #[serde(default)]
    pub last_version_id: String,
    #[serde(default)]
    pub onboarded: bool,
}

fn d45() -> i32 { 45 }
fn d2048() -> i32 { 2048 }
fn d512() -> i32 { 512 }
fn d1() -> i32 { 1 }
fn d1120() -> i32 { 1120 }
fn d720() -> i32 { 720 }
fn d32() -> i32 { 32 }
fn dtrue() -> bool { true }

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            theme_mode: 0,
            background_image_path: String::new(),
            background_opacity: 45,
            background_blur: 0,
            game_directory: String::new(),
            java_search_paths: Vec::new(),
            max_memory_mb: 2048,
            min_memory_mb: 512,
            jvm_arguments: String::new(),
            game_arguments: String::new(),
            java_path: String::new(),
            launcher_behavior: 1,
            process_priority: 0,
            server_address: String::new(),
            pre_launch_command: String::new(),
            launch_environment: Vec::new(),
            wrapper_command: String::new(),
            fullscreen: false,
            window_width: 0,
            window_height: 0,
            window_launcher_width: 1120,
            window_launcher_height: 720,
            download_source_index: 0,
            auto_fallback: true,
            concurrency: 32,
            verify_files: true,
            version_isolation: true,
            auto_install_java: true,
            last_account_id: String::new(),
            last_version_id: String::new(),
            onboarded: false,
        }
    }
}

fn settings_path() -> PathBuf {
    crate::core::paths::paths().fmcl_root.join("config.json")
}

static SETTINGS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 读取全局设置（缺失/损坏返回默认值）
pub fn load_settings() -> AppSettings {
    let _g = SETTINGS_LOCK.lock().unwrap();
    let path = settings_path();
    if !path.exists() {
        return AppSettings::default();
    }
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => AppSettings::default(),
    }
}

/// 保存全局设置（原子写）
pub fn save_settings(settings: &AppSettings) -> Result<()> {
    let _g = SETTINGS_LOCK.lock().unwrap();
    let path = settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(settings)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// 生效的游戏根目录（设置值为空时取 exe 所在目录\.minecraft）
pub fn effective_game_dir(settings: &AppSettings) -> PathBuf {
    let s = settings.game_directory.trim();
    if s.is_empty() {
        crate::core::paths::paths().default_game_dir.clone()
    } else {
        PathBuf::from(s)
    }
}

// ---------------------------------------------------------------------------
// 版本设置（PCL2 式：全局继承 + 局部覆盖）
// ---------------------------------------------------------------------------

/// 每版本独立设置，字段缺省 = 跟随全局
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VersionSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isolation: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub java_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_memory_mb: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_memory_mb: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jvm_arguments: Option<String>,
}

impl VersionSettings {
    pub fn is_empty(&self) -> bool {
        self.isolation.is_none()
            && self
                .java_path
                .as_ref()
                .map(|s| s.is_empty())
                .unwrap_or(true)
            && self.max_memory_mb.unwrap_or(0) == 0
            && self.min_memory_mb.unwrap_or(0) == 0
            && self
                .jvm_arguments
                .as_ref()
                .map(|s| s.trim().is_empty())
                .unwrap_or(true)
    }
}

/// 启动时实际生效的配置（全局 + 版本覆盖合并结果）
#[derive(Debug, Clone)]
pub struct EffectiveLaunchConfig {
    /// 隔离时为 versions/<id>，否则为游戏根目录
    pub work_dir: PathBuf,
    pub assets_dir: PathBuf,
    pub libraries_dir: PathBuf,
    pub isolated: bool,
    /// 版本级 Java 覆盖（空 = 全局策略）
    pub java_path: String,
    pub min_memory_mb: i32,
    pub max_memory_mb: i32,
    /// 全局 + 版本叠加后的额外 JVM 参数
    pub jvm_arguments: String,
}

pub fn version_settings_path(game_dir: &Path, version_id: &str) -> PathBuf {
    game_dir
        .join("versions")
        .join(version_id)
        .join("fmcl-settings.json")
}

/// 读取版本设置（文件缺失返回默认）
pub fn load_version_settings(game_dir: &Path, version_id: &str) -> VersionSettings {
    let path = version_settings_path(game_dir, version_id);
    if !path.exists() {
        return VersionSettings::default();
    }
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// 保存版本设置（空设置时删除文件）
pub fn save_version_settings(
    game_dir: &Path,
    version_id: &str,
    settings: &VersionSettings,
) -> Result<()> {
    let path = version_settings_path(game_dir, version_id);
    if settings.is_empty() {
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        return Ok(());
    }
    std::fs::create_dir_all(path.parent().unwrap())?;
    std::fs::write(&path, serde_json::to_vec_pretty(settings)?)?;
    Ok(())
}

/// 合并全局与版本设置（PCL2 语义）
pub fn resolve_launch_config(
    global: &AppSettings,
    game_dir: &Path,
    version_id: &str,
    version: &VersionSettings,
) -> EffectiveLaunchConfig {
    let isolated = version.isolation.unwrap_or(global.version_isolation);
    let work_dir = if isolated {
        game_dir.join("versions").join(version_id)
    } else {
        game_dir.to_path_buf()
    };
    let java_path = version
        .java_path
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_default();
    let min_memory_mb = match version.min_memory_mb {
        Some(v) if v > 0 => v,
        _ => global.min_memory_mb,
    };
    let max_memory_mb = match version.max_memory_mb {
        Some(v) if v > 0 => v,
        _ => global.max_memory_mb,
    };
    let mut jvm_args = global.jvm_arguments.trim().to_string();
    if let Some(extra) = &version.jvm_arguments {
        let extra = extra.trim();
        if !extra.is_empty() {
            if !jvm_args.is_empty() {
                jvm_args.push(' ');
            }
            jvm_args.push_str(extra);
        }
    }
    EffectiveLaunchConfig {
        work_dir,
        assets_dir: game_dir.join("assets"),
        libraries_dir: game_dir.join("libraries"),
        isolated,
        java_path,
        min_memory_mb,
        max_memory_mb,
        jvm_arguments: jvm_args,
    }
}

/// 该版本某子目录的落点（随隔离变化）：mods / resourcepacks / shaderpacks / saves 等
pub fn versioned_subdir(global: &AppSettings, game_dir: &Path, version_id: &str, sub: &str) -> PathBuf {
    let vs = load_version_settings(game_dir, version_id);
    let isolated = vs.isolation.unwrap_or(global.version_isolation);
    if isolated {
        game_dir.join("versions").join(version_id).join(sub)
    } else {
        game_dir.join(sub)
    }
}
