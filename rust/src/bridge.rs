//! 手写 C-ABI JSON-RPC 桥（替代 flutter_rust_bridge 代码生成）。
//!
//! 通信模型（Flutter 只做渲染与通信）：
//!
//! - Dart 侧调用 `fmcl_call(method, payload_json)`，Rust 在 tokio 运行时中
//!   异步执行 [`crate::dispatch::dispatch`]，完成后经事件回调回传
//!   `{"type":"response","id":N,"ok":..,"value":..}`（或 `"error"`）。
//! - 流式方法（安装/启动/补全/下载/登录）在执行过程中随时经回调推送
//!   `{"type":"event","id":N,"event":{...}}`，Dart 侧还原为 `Stream<T>`。
//! - 启动器日志由 `fmcl_init` 内部订阅 broadcast 通道，以
//!   `{"type":"app_log","event":{...}}` 持续推送（id 恒为 0）。
//! - 回调可能在任意 Rust 工作线程触发，Dart 侧用 `NativeCallable.listener`
//!   接收（自动投递到持有 isolate 的消息循环）。
//!
//! 字符串与内存约定：payload 与回调 JSON 均为 UTF-8、`\0` 结尾；
//! Rust 分配的返回字符串由 `fmcl_free` 释放（当前接口无同步返回字符串，
//! 保留该导出以备将来扩展同步查询接口）。

use once_cell::sync::Lazy;
use serde_json::Value;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Mutex;

/// Dart 注册的事件回调（线程安全：Dart 侧为 NativeCallable.listener）
type EventCallback = extern "C" fn(*const c_char);

static EVENT_CB: Lazy<Mutex<Option<EventCallback>>> = Lazy::new(|| Mutex::new(None));
static NEXT_ID: AtomicI64 = AtomicI64::new(1);

/// tokio 全局运行时（多线程，承载全部业务异步任务）
static RUNTIME: Lazy<tokio::runtime::Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(4)
        .thread_name("fmcl-worker")
        .build()
        .expect("创建 tokio 运行时失败")
});

/// 在任意线程安全地投递一条事件 JSON
pub fn emit_event(json: &str) {
    let guard = EVENT_CB.lock().unwrap();
    if let Some(cb) = *guard {
        if let Ok(c) = CString::new(json) {
            cb(c.as_ptr());
        }
    }
}

/// 绑定到一次调用的流式事件发射器
#[derive(Clone)]
pub struct Emitter {
    /// 当前调用的 id（与 response 的 id 一致，Dart 据此归流）
    pub call_id: i64,
}

impl Emitter {
    /// 推送一条流式事件（序列化失败时静默丢弃，不中断业务）
    pub fn send(&self, event: &impl serde::Serialize) {
        let Ok(payload) = serde_json::to_string(event) else {
            return;
        };
        emit_event(&format!(
            "{{\"type\":\"event\",\"id\":{},\"event\":{payload}}}",
            self.call_id
        ));
    }
}

/// 获取全局运行时句柄（内部模块需要 spawn 时使用）
pub fn runtime() -> &'static tokio::runtime::Runtime {
    &RUNTIME
}

// ---------------------------------------------------------------------------
// C-ABI 导出
// ---------------------------------------------------------------------------

/// 初始化运行时与全局转发（幂等）。返回 0 表示成功。
#[no_mangle]
pub extern "C" fn fmcl_init() -> i32 {
    Lazy::force(&RUNTIME);

    // 启动器日志广播 → 事件流（id 恒为 0；订阅一次，进程生命周期内有效）
    static LOG_FWD_STARTED: std::sync::Once = std::sync::Once::new();
    LOG_FWD_STARTED.call_once(|| {
        if let Some(mut rx) = crate::core::logging::subscribe() {
            RUNTIME.spawn(async move {
                loop {
                    match rx.recv().await {
                        Ok(entry) => {
                            let Ok(payload) = serde_json::to_string(&entry) else {
                                continue;
                            };
                            emit_event(&format!(
                                "{{\"type\":\"app_log\",\"event\":{payload}}}"
                            ));
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(_) => break,
                    }
                }
            });
        }
    });
    0
}

/// 注册事件回调（Dart 启动时调用一次）
#[no_mangle]
pub extern "C" fn fmcl_set_event_callback(cb: EventCallback) {
    *EVENT_CB.lock().unwrap() = Some(cb);
}

/// 异步调用一个方法。立即返回调用 id；结果与过程事件经回调回传。
///
/// # Safety
/// `method` 与 `payload` 必须为合法的以 \0 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn fmcl_call(method: *const c_char, payload: *const c_char) -> i64 {
    let method = if method.is_null() {
        String::new()
    } else {
        CStr::from_ptr(method).to_string_lossy().into_owned()
    };
    let payload = if payload.is_null() {
        Value::Null
    } else {
        let raw = CStr::from_ptr(payload).to_string_lossy();
        serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null)
    };

    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    RUNTIME.spawn(async move {
        // 内层 spawn + JoinError 兜底：即使 handler panic（任务中止），
        // 也保证向 Dart 回传 ok:false，绝不让调用方永久挂起。
        let result = tokio::task::spawn(async move {
            crate::dispatch::dispatch(&method, payload, Emitter { call_id: id }).await
        })
        .await
        .unwrap_or_else(|join_err| {
            Err(anyhow::anyhow!("内部任务异常（已捕获）: {join_err}"))
        });
        let response = match result {
            Ok(value) => {
                let v = serde_json::to_string(&value).unwrap_or_else(|_| "null".into());
                format!("{{\"type\":\"response\",\"id\":{id},\"ok\":true,\"value\":{v}}}")
            }
            Err(e) => {
                let msg = serde_json::to_string(&e.to_string())
                    .unwrap_or_else(|_| "\"执行失败\"".into());
                format!("{{\"type\":\"response\",\"id\":{id},\"ok\":false,\"error\":{msg}}}")
            }
        };
        emit_event(&response);
    });
    id
}

/// 预留：释放 Rust 侧分配的 C 字符串
///
/// # Safety
/// `ptr` 必须是由本库分配且未被释放的指针。
#[no_mangle]
pub unsafe extern "C" fn fmcl_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
