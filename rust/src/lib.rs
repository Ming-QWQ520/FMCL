//! FMCL Rust 后端核心 (rust_lib_fmcl)
//!
//! 架构：全部业务逻辑在 Rust 侧，Flutter 仅负责渲染与通信。
//!
//! - [`core`]：目录解析、日志系统、设置存储、账户存储
//! - [`api`]：业务能力（应用初始化/设置/清单/版本管理/安装/补全/启动/
//!   账户/内容下载/Java/进程/系统信息）
//! - [`util`]：HTTP 下载引擎、取消注册表
//! - [`bridge`]：手写 C-ABI JSON-RPC 桥（无需代码生成）
//! - [`dispatch`]：方法分发表（method 名 → 业务函数）
//!
//! Dart 侧通过 `fmcl_call` 异步调用全部能力，过程事件与结果经单一
//! 事件回调回传；启动器日志由 `fmcl_init` 内部持续推送。

pub mod api;
pub mod bridge;
pub mod core;
pub mod dispatch;
pub mod util;
