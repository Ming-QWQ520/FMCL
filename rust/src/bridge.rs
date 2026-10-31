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
//!
//! 同步通道：`fmcl_ping`（健康检查）与 `fmcl_call_sync`（启动关键路径的
//! 同步调用，直接回写响应 JSON，不依赖事件回调管线）供 Dart 启动期使用。

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

/// 在任意线程安全地投递一条事件 JSON。
///
/// 内存所有权约定（关键！）：Dart 侧事件回调是 `NativeCallable.listener`，
/// 它只把指针值异步投递到 Dart isolate —— 回调返回后 Dart 才会读取该指针
/// 指向的内存。因此这里绝不能传 `CString::as_ptr()`（函数返回后字符串
/// 立即被释放，Dart 读到已释放内存：轻则 JSON 解析失败被静默吞掉、表现为
/// 所有异步调用的响应随机丢失 —— 登录卡住/下载转圈/关窗无反应；重则崩溃）。
/// 必须用 `into_raw` 转移交出所有权，由 Dart 侧读完后再经 `fmcl_free` 归还。
pub fn emit_event(json: &str) {
    let guard = EVENT_CB.lock().unwrap();
    if let Some(cb) = *guard {
        if let Ok(c) = CString::new(json) {
            let raw = c.into_raw();
            cb(raw);
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

/// 同步健康检查（Dart 启动时调用）：返回魔法数 + ABI 版本，
/// 用于校验 DLL 完整且与前端配套（防止旧版/半解压 DLL 造成诡异故障）。
#[no_mangle]
pub extern "C" fn fmcl_ping() -> i64 {
    ((0x464D_434C_i64) << 32) | FMCL_ABI_VERSION as i64
}

/// 桥接 ABI 版本（与 Dart 侧 RustFfi.abiVersion 严格一致）
///
/// v2：事件内存所有权变更 —— emit_event 改为 into_raw 移交，
/// Dart 读后经 fmcl_free 归还（v1 存在 use-after-free）。
pub const FMCL_ABI_VERSION: u32 = 2;

/// 初始化运行时与全局转发（幂等）。返回 0 表示成功。
#[no_mangle]
pub extern "C" fn fmcl_init() -> i32 {
    Lazy::force(&RUNTIME);
    crate::log_info!("Core", "tokio 运行时已就绪（fmcl_init）");

    // 启动器日志广播 → 事件流（id 恒为 0；订阅一次，进程生命周期内有效）。
    // 注意：fmcl_init 时日志系统尚未初始化（init_app 才会初始化），
    // 因此转发协程必须等待日志系统就绪后再订阅，绝不能此处直接
    // subscribe()——那会得到 None 并永远不再尝试（历史 bug）。
    static LOG_FWD_STARTED: std::sync::Once = std::sync::Once::new();
    LOG_FWD_STARTED.call_once(|| {
        RUNTIME.spawn(async move {
            let mut rx = loop {
                if let Some(rx) = crate::core::logging::subscribe() {
                    break rx;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            };
            crate::log_info!("Core", "日志转发协程已订阅（app_log → UI）");
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
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        crate::log_warn!("Core", "日志转发落后 {n} 条，已跳过");
                        continue;
                    }
                    Err(_) => break,
                }
            }
        });
    });
    0
}

/// 注册事件回调（Dart 启动时调用一次）
#[no_mangle]
pub extern "C" fn fmcl_set_event_callback(cb: EventCallback) {
    *EVENT_CB.lock().unwrap() = Some(cb);
    crate::log_info!("Core", "事件回调已注册");
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
    crate::log_info!("Core", "收到调用 id={id} method={method}");
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
        let ok = matches!(result, Ok(_));
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
        crate::log_info!("Core", "响应已回传 id={id} ok={ok}");
        if let Err(e) = &result {
            // 失败响应必须记录错误文本：ok=false 只有 id 时无法排查
            // （例：yggdrasil 登录失败原因只存在于错误字符串里）
            crate::log_warn!("Core", "调用失败 id={id} error={e}");
        }
        emit_event(&response);
    });
    id
}

/// 同步调用（启动关键路径专用）：在调用线程上直接执行并回写响应 JSON，
/// 不依赖事件回调管线（即便回调失效也能完成初始化）。
///
/// 返回值：0 = 成功且已写入 out_buf；>0 = 所需缓冲区字节数（out_buf 不足，
/// 未写入，Dart 应按该大小重试一次）；<0 = 内部错误。
///
/// # Safety
/// - `method`/`payload` 必须为合法的以 \0 结尾的 UTF-8 C 字符串（可为 null）。
/// - `out_buf`/`cap` 必须指向调用方分配的可写缓冲区（cap 为字节数，含 \0 空间）。
#[no_mangle]
pub unsafe extern "C" fn fmcl_call_sync(
    method: *const c_char,
    payload: *const c_char,
    out_buf: *mut c_char,
    cap: usize,
) -> i64 {
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

    crate::log_info!("Core", "同步调用 method={method}");
    let started = std::time::Instant::now();
    let method_for_log = method.clone();
    // 内层 spawn + JoinError 兜底：即使 handler panic（任务中止）也不会
    // 跨 FFI 边界展开导致整个进程崩溃，而是回传 ok:false。
    let result = RUNTIME.block_on(async {
        tokio::task::spawn(async move {
            crate::dispatch::dispatch(&method, payload, Emitter { call_id: 0 }).await
        })
        .await
        .unwrap_or_else(|join_err| Err(anyhow::anyhow!("内部任务异常（已捕获）: {join_err}")))
    });

    let response = match &result {
        Ok(value) => {
            let v = serde_json::to_string(value).unwrap_or_else(|_| "null".into());
            format!("{{\"type\":\"response\",\"id\":0,\"ok\":true,\"value\":{v}}}")
        }
        Err(e) => {
            let msg = serde_json::to_string(&e.to_string())
                .unwrap_or_else(|_| "\"执行失败\"".into());
            format!("{{\"type\":\"response\",\"id\":0,\"ok\":false,\"error\":{msg}}}")
        }
    };
    let ok = matches!(result, Ok(_));
    crate::log_info!(
        "Core",
        "同步调用完成 method={} ok={} 耗时={:?}",
        method_for_log,
        ok,
        started.elapsed()
    );

    let bytes = response.as_bytes();
    let needed = bytes.len() + 1;
    if out_buf.is_null() || cap < needed {
        return needed as i64;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf.cast::<u8>(), bytes.len());
    *out_buf.add(bytes.len()) = 0;
    0
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
