//! 会话级取消注册表。
//!
//! Dart 侧通过 `create_download_session` 拿到 id，
//! 需要取消时调用 `cancel_download(id)`，下载循环内每次迭代检查标志位。

use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub struct CancelRegistry {
    map: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

pub static CANCEL_REGISTRY: Lazy<CancelRegistry> =
    Lazy::new(|| CancelRegistry { map: Mutex::new(HashMap::new()) });

impl CancelRegistry {
    pub fn global() -> &'static CancelRegistry {
        &CANCEL_REGISTRY
    }

    pub fn create(&self, id: &str) {
        self.map
            .lock()
            .unwrap()
            .insert(id.to_string(), Arc::new(AtomicBool::new(false)));
    }

    /// 会话是否已注册
    pub fn contains(&self, id: &str) -> bool {
        self.map.lock().unwrap().contains_key(id)
    }

    pub fn handle(&self, id: &str) -> Arc<AtomicBool> {
        self.map
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .unwrap_or_else(|| Arc::new(AtomicBool::new(false)))
    }

    pub fn cancel(&self, id: &str) {
        if let Some(flag) = self.map.lock().unwrap().get(id) {
            flag.store(true, Ordering::Relaxed);
        }
    }

    pub fn dispose(&self, id: &str) {
        self.map.lock().unwrap().remove(id);
    }
}
