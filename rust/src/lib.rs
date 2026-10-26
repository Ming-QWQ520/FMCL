//! FMCL Rust 后端核心 (rust_lib_fmcl)
//!
//! 通过 flutter_rust_bridge 暴露给 Dart 层的能力：
//! - 并发下载引擎（多连接、重试、SHA1 校验、实时进度）
//! - 文件哈希（SHA1 / MD5）
//! - Zip/Natives 解压、Jar 条目读取
//! - Java 运行时检测
//! - 游戏子进程管理（日志流式回传、退出码、终止）
//! - 系统信息（内存、CPU、架构）
//!
//! 所有公开 API 位于 [`api`] 模块，由 FRB 代码生成为 Dart 绑定。

pub mod api;
pub mod util;

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
