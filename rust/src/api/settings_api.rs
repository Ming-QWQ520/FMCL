//! 设置 API（Flutter 只做展示与编辑，持久化与合并逻辑全部在 Rust）。

use crate::core::settings as s;
use anyhow::Result;

/// 全局设置（FRB 映射结构，与 core::settings::AppSettings 字段一一对应）
#[derive(Debug, Clone, Default)]
pub struct SettingsData {
    pub theme_mode: i32,
    pub background_image_path: String,
    pub background_opacity: i32,
    pub background_blur: i32,
    pub game_directory: String,
    pub java_search_paths: Vec<String>,
    pub max_memory_mb: i32,
    pub min_memory_mb: i32,
    pub jvm_arguments: String,
    pub game_arguments: String,
    pub java_path: String,
    pub launcher_behavior: i32,
    pub process_priority: i32,
    pub server_address: String,
    pub pre_launch_command: String,
    pub launch_environment: Vec<String>,
    pub wrapper_command: String,
    pub fullscreen: bool,
    pub window_width: i32,
    pub window_height: i32,
    pub window_launcher_width: i32,
    pub window_launcher_height: i32,
    pub download_source_index: i32,
    pub auto_fallback: bool,
    pub concurrency: i32,
    pub verify_files: bool,
    pub version_isolation: bool,
    pub auto_install_java: bool,
    pub last_account_id: String,
    pub last_version_id: String,
    pub onboarded: bool,
}

impl From<s::AppSettings> for SettingsData {
    fn from(v: s::AppSettings) -> Self {
        SettingsData {
            theme_mode: v.theme_mode,
            background_image_path: v.background_image_path,
            background_opacity: v.background_opacity,
            background_blur: v.background_blur,
            game_directory: v.game_directory,
            java_search_paths: v.java_search_paths,
            max_memory_mb: v.max_memory_mb,
            min_memory_mb: v.min_memory_mb,
            jvm_arguments: v.jvm_arguments,
            game_arguments: v.game_arguments,
            java_path: v.java_path,
            launcher_behavior: v.launcher_behavior,
            process_priority: v.process_priority,
            server_address: v.server_address,
            pre_launch_command: v.pre_launch_command,
            launch_environment: v.launch_environment,
            wrapper_command: v.wrapper_command,
            fullscreen: v.fullscreen,
            window_width: v.window_width,
            window_height: v.window_height,
            window_launcher_width: v.window_launcher_width,
            window_launcher_height: v.window_launcher_height,
            download_source_index: v.download_source_index,
            auto_fallback: v.auto_fallback,
            concurrency: v.concurrency,
            verify_files: v.verify_files,
            version_isolation: v.version_isolation,
            auto_install_java: v.auto_install_java,
            last_account_id: v.last_account_id,
            last_version_id: v.last_version_id,
            onboarded: v.onboarded,
        }
    }
}

impl From<&SettingsData> for s::AppSettings {
    fn from(v: &SettingsData) -> Self {
        s::AppSettings {
            theme_mode: v.theme_mode,
            background_image_path: v.background_image_path.clone(),
            background_opacity: v.background_opacity,
            background_blur: v.background_blur,
            game_directory: v.game_directory.clone(),
            java_search_paths: v.java_search_paths.clone(),
            max_memory_mb: v.max_memory_mb,
            min_memory_mb: v.min_memory_mb,
            jvm_arguments: v.jvm_arguments.clone(),
            game_arguments: v.game_arguments.clone(),
            java_path: v.java_path.clone(),
            launcher_behavior: v.launcher_behavior,
            process_priority: v.process_priority,
            server_address: v.server_address.clone(),
            pre_launch_command: v.pre_launch_command.clone(),
            launch_environment: v.launch_environment.clone(),
            wrapper_command: v.wrapper_command.clone(),
            fullscreen: v.fullscreen,
            window_width: v.window_width,
            window_height: v.window_height,
            window_launcher_width: v.window_launcher_width,
            window_launcher_height: v.window_launcher_height,
            download_source_index: v.download_source_index,
            auto_fallback: v.auto_fallback,
            concurrency: v.concurrency,
            verify_files: v.verify_files,
            version_isolation: v.version_isolation,
            auto_install_java: v.auto_install_java,
            last_account_id: v.last_account_id.clone(),
            last_version_id: v.last_version_id.clone(),
            onboarded: v.onboarded,
        }
    }
}

/// 读取全局设置
pub fn get_settings() -> SettingsData {
    s::load_settings().into()
}

/// 保存全局设置
pub fn save_settings(settings: SettingsData) -> Result<()> {
    s::save_settings(&s::AppSettings::from(&settings))
}

/// 生效的游戏根目录（设置值为空时 = exe 所在目录\.minecraft）
pub fn effective_game_directory() -> String {
    let settings = s::load_settings();
    s::effective_game_dir(&settings)
        .to_string_lossy()
        .into_owned()
}

/// 记录上次选中版本
pub fn set_last_version(version_id: String) -> Result<()> {
    let mut settings = s::load_settings();
    settings.last_version_id = version_id;
    s::save_settings(&settings)
}

/// 记录上次使用账户
pub fn set_last_account(account_id: String) -> Result<()> {
    let mut settings = s::load_settings();
    settings.last_account_id = account_id;
    s::save_settings(&settings)
}

/// 版本设置（缺省字段 = 跟随全局）
#[derive(Debug, Clone, Default)]
pub struct VersionSettingsData {
    pub isolation: Option<bool>,
    pub java_path: Option<String>,
    pub max_memory_mb: Option<i32>,
    pub min_memory_mb: Option<i32>,
    pub jvm_arguments: Option<String>,
}

impl From<s::VersionSettings> for VersionSettingsData {
    fn from(v: s::VersionSettings) -> Self {
        VersionSettingsData {
            isolation: v.isolation,
            java_path: v.java_path,
            max_memory_mb: v.max_memory_mb,
            min_memory_mb: v.min_memory_mb,
            jvm_arguments: v.jvm_arguments,
        }
    }
}

impl From<&VersionSettingsData> for s::VersionSettings {
    fn from(v: &VersionSettingsData) -> Self {
        s::VersionSettings {
            isolation: v.isolation,
            java_path: v.java_path.clone(),
            max_memory_mb: v.max_memory_mb,
            min_memory_mb: v.min_memory_mb,
            jvm_arguments: v.jvm_arguments.clone(),
        }
    }
}

/// 读取版本设置
pub fn get_version_settings(game_dir: String, version_id: String) -> VersionSettingsData {
    s::load_version_settings(std::path::Path::new(&game_dir), &version_id).into()
}

/// 保存版本设置
pub fn save_version_settings(
    game_dir: String,
    version_id: String,
    settings: VersionSettingsData,
) -> Result<()> {
    s::save_version_settings(
        std::path::Path::new(&game_dir),
        &version_id,
        &s::VersionSettings::from(&settings),
    )
}
