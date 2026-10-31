//! 账户存储（`<FMCL 根>/accounts.json`）。
//!
//! 支持离线 / 微软 / Yggdrasil 外置账户；多账户 + 当前账户选择。

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 统一账户模型
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    /// offline | microsoft | yggdrasil
    pub account_type: String,
    pub name: String,
    /// 访问令牌（微软为 MC Services JWT；离线为 0）
    #[serde(default)]
    pub access_token: String,
    #[serde(default)]
    pub uuid: String,
    /// Yggdrasil 认证服务器 API 根
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub yggdrasil_server: Option<String>,
    /// Yggdrasil 角色 profile id
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    /// 令牌过期时间（毫秒时间戳）
    #[serde(default)]
    pub expires_at: i64,
    /// 刷新令牌（微软）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// 客户端令牌（Yggdrasil validate/refresh 用）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_token: Option<String>,
    /// 皮肤 URL
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skin_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct AccountStore {
    #[serde(default)]
    accounts: Vec<Account>,
    #[serde(default)]
    current_id: String,
}

fn store_path() -> PathBuf {
    crate::core::paths::paths().fmcl_root.join("accounts.json")
}

fn read_store() -> AccountStore {
    let path = store_path();
    if !path.exists() {
        return AccountStore::default();
    }
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write_store(store: &AccountStore) -> Result<()> {
    let path = store_path();
    std::fs::create_dir_all(path.parent().unwrap())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(store)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// 列出全部账户
pub fn list_accounts() -> Vec<Account> {
    read_store().accounts
}

/// 当前账户
pub fn current_account() -> Option<Account> {
    let store = read_store();
    store
        .accounts
        .iter()
        .find(|a| a.id == store.current_id)
        .cloned()
        .or_else(|| store.accounts.first().cloned())
}

/// 保存（新增或更新）账户并设为当前
pub fn upsert_account(account: Account) -> Result<()> {
    let mut store = read_store();
    if let Some(existing) = store.accounts.iter_mut().find(|a| a.id == account.id) {
        *existing = account.clone();
    } else {
        store.accounts.push(account.clone());
    }
    store.current_id = account.id.clone();
    write_store(&store)
}

/// 仅更新当前选择
pub fn set_current(id: &str) -> Result<()> {
    let mut store = read_store();
    if store.accounts.iter().any(|a| a.id == id) {
        store.current_id = id.to_string();
        write_store(&store)?;
    }
    Ok(())
}

/// 删除账户；若删除的是当前账户则回退到第一个
pub fn delete_account(id: &str) -> Result<()> {
    let mut store = read_store();
    store.accounts.retain(|a| a.id != id);
    if store.current_id == id {
        store.current_id = store.accounts.first().map(|a| a.id.clone()).unwrap_or_default();
    }
    write_store(&store)
}

/// 离线模式 UUID（与 Mojang 离线算法一致：MD5("OfflinePlayer:<name>") v3）
pub fn offline_uuid(player_name: &str) -> String {
    use md5::{Digest, Md5};
    let mut hasher = Md5::new();
    hasher.update(format!("OfflinePlayer:{player_name}").as_bytes());
    let bytes = hasher.finalize();
    let mut b = bytes.0;
    b[6] = (b[6] & 0x0f) | 0x30;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// 生成新账户 id
pub fn new_account_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("acc_{nanos:x}")
}
