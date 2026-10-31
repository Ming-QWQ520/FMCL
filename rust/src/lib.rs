//! FMCL Rust 后端核心 (rust_lib_fmcl)
//!
//! 架构：全部业务逻辑在 Rust 侧，Flutter 仅负责渲染与通信。
//!
//! - [`core`]：目录解析、日志系统、设置存储、账户存储
//! - [`api`]：FRB 暴露给 Dart 的能力（应用初始化/设置/清单/版本管理/
//!   安装/补全/启动/账户/内容下载/Java/进程/系统信息）
//! - [`util`]：HTTP 下载引擎、取消注册表
//!
//! 通过 flutter_rust_bridge 暴露给 Dart 层的能力：
//! - 便携目录解析 + 启动器日志（文件落盘 + 实时流）
//! - 并发下载引擎（多连接、重试、SHA1 校验、实时进度、镜像回退）
//! - 版本安装（原版 + Forge/NeoForge/Fabric/Quilt/OptiFine 合并安装）
//! - 文件补全、外部版本导入、版本重命名/删除/复制
//! - 完整启动管线（Java 选择/自动安装、natives、参数构建、日志流、崩溃分析）
//! - 账户（离线/微软设备码/Yggdrasil 外置 + authlib-injector 自动下载）
//! - 资源下载（Modrinth 搜索下载、整合包安装）
//! - Zip/Natives 解压、文件哈希、Java 检测、服务端 ping

pub mod api;
pub mod core;
pub mod util;

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
