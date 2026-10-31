//! FMCL 核心业务模块（非 FRB 直接暴露，由 `api` 层包装调用）。
//!
//! 全部启动器业务逻辑都实现在 Rust 侧：目录解析、日志、设置存储、
//! 账户存储。Flutter 仅负责渲染与通信。

pub mod logging;
pub mod paths;
pub mod settings;
pub mod store;
