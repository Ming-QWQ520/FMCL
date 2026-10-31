//! 账户与登录 API。
//!
//! - 离线账户：本地 MD5 离线 UUID（与官方算法一致）
//! - 微软账户：OAuth 设备码流程（公开客户端，开源启动器通用）→ XBL → XSTS →
//!   Minecraft Services；支持刷新令牌续期
//! - Yggdrasil 外置账户（authlib-injector 规范）：元数据探测 / 密码登录 /
//!   validate+refresh 续期
//! - authlib-injector.jar 自动下载至 `exe 所在目录\FMCL\lib\authlib-injector`
//!   （对齐 PCL 外置登录处理方式）

use crate::core::store::{self, Account};
use anyhow::{anyhow, bail, Result};
use serde_json::{json, Value};
use std::path::Path;

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(12))
        .read_timeout(std::time::Duration::from_secs(45))
        .timeout(std::time::Duration::from_secs(120))
        .user_agent("FMCL/0.1.0 (github.com/Ming-QWQ520/FMCL)")
        .build()?)
}

// ---------------------------------------------------------------------------
// 账户 CRUD（Flutter 展示）
// ---------------------------------------------------------------------------

/// 列出全部账户
pub fn list_accounts() -> Result<Vec<Account>> {
    Ok(store::list_accounts())
}

/// 当前账户
pub fn get_current_account() -> Result<Option<Account>> {
    Ok(store::current_account())
}

/// 选择当前账户
pub fn select_account(id: String) -> Result<()> {
    store::set_current(&id)
}

/// 删除账户
pub fn remove_account(id: String) -> Result<()> {
    store::delete_account(&id)
}

/// 添加离线账户
pub fn add_offline_account(name: String) -> Result<Account> {
    let name = name.trim().to_string();
    anyhow::ensure!(!name.is_empty(), "玩家名不能为空");
    anyhow::ensure!(name.len() <= 16, "玩家名过长（最多 16 字符）");
    let account = Account {
        id: store::new_account_id(),
        account_type: "offline".into(),
        name: name.clone(),
        access_token: "0".into(),
        uuid: store::offline_uuid(&name),
        yggdrasil_server: None,
        profile_id: None,
        expires_at: 0,
        refresh_token: None,
        client_token: None,
        skin_url: None,
    };
    store::upsert_account(account.clone())?;
    crate::log_info!("Auth", "添加离线账户: {name}");
    Ok(account)
}

/// 通用保存（外部登录流程组装完成后调用）
pub fn save_account(account: Account) -> Result<()> {
    store::upsert_account(account)
}

// ---------------------------------------------------------------------------
// Yggdrasil 外置登录（authlib-injector 规范）
// ---------------------------------------------------------------------------

/// 服务端元数据
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct YggdrasilServerMeta {
    pub api_root: String,
    pub server_name: String,
}

/// 规范化服务器地址
pub fn normalize_server_url(input: String) -> String {
    let mut url = input.trim().to_string();
    if url.is_empty() {
        return url;
    }
    if !url.starts_with("http://") && !url.starts_with("https://") {
        url = format!("https://{url}");
    }
    while url.ends_with('/') {
        url.pop();
    }
    url
}

/// 探测认证服务器元数据（返回 API 根；authlib-injector ALI 头规范）
pub async fn yggdrasil_server_meta(server_url: String) -> Result<YggdrasilServerMeta> {
    let normalized = normalize_server_url(server_url);
    anyhow::ensure!(!normalized.is_empty(), "认证服务器地址不能为空");
    let c = client()?;
    let resp = c
        .get(format!("{normalized}/api/yggdrasil"))
        .send()
        .await
        .map_err(|e| anyhow!("认证服务器不可达: {normalized} ({e})"))?;
    anyhow::ensure!(
        resp.status().is_success(),
        "无法连接认证服务器 (HTTP {})",
        resp.status()
    );
    let ali = resp
        .headers()
        .get("x-authlib-injector-api-location")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let meta: Value = resp.json().await.unwrap_or(Value::Null);
    let mut api_root = normalized.clone();
    if let Some(loc) = ali {
        // 相对地址解析
        api_root = if loc.starts_with("http://") || loc.starts_with("https://") {
            loc.trim_end_matches('/').to_string()
        } else {
            format!("{normalized}/{}", loc.trim_start_matches('/'))
                .trim_end_matches('/')
                .to_string()
        };
        while api_root.ends_with('/') {
            api_root.pop();
        }
    }
    let server_name = meta
        .pointer("/meta/serverName")
        .and_then(|v| v.as_str())
        .unwrap_or(&normalized)
        .to_string();
    Ok(YggdrasilServerMeta { api_root, server_name })
}

/// 外置角色档案
#[derive(Debug, Clone, serde::Serialize)]
pub struct YggdrasilProfile {
    pub id: String,
    pub name: String,
}

/// 登录会话
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct YggdrasilSession {
    pub access_token: String,
    pub client_token: String,
    pub api_root: String,
    pub profiles: Vec<YggdrasilProfile>,
}

/// 账号密码登录外置认证服务器
pub async fn yggdrasil_login(
    server_url: String,
    username: String,
    password: String,
) -> Result<YggdrasilSession> {
    let meta = yggdrasil_server_meta(server_url).await?;
    let c = client()?;
    let resp = c
        .post(format!("{}/authserver/authenticate", meta.api_root))
        .json(&json!({
            "agent": {"name": "Minecraft", "version": 1},
            "username": username,
            "password": password,
            "requestUser": true,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("登录请求失败: {e}"))?;
    let status = resp.status();
    let data: Value = resp.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let msg = data["errorMessage"]
            .as_str()
            .unwrap_or("认证失败")
            .to_string();
        bail!("{msg}");
    }
    let token = data["accessToken"]
        .as_str()
        .ok_or_else(|| anyhow!("认证服务器返回缺少 accessToken"))?
        .to_string();
    let client_token = data["clientToken"].as_str().unwrap_or("").to_string();
    let profiles: Vec<YggdrasilProfile> = data["availableProfiles"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|p| {
                    Some(YggdrasilProfile {
                        id: p["id"].as_str()?.to_string(),
                        name: p["name"].as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    anyhow::ensure!(!profiles.is_empty(), "该账户没有可用的角色档案");
    crate::log_info!("Auth", "外置登录成功: {}@{}", profiles[0].name, meta.api_root);
    Ok(YggdrasilSession {
        access_token: token,
        client_token,
        api_root: meta.api_root,
        profiles,
    })
}

/// 以指定角色档案保存外置账户
pub fn save_yggdrasil_account(
    api_root: String,
    access_token: String,
    client_token: String,
    profile_id: String,
    profile_name: String,
) -> Result<Account> {
    let account = Account {
        id: store::new_account_id(),
        account_type: "yggdrasil".into(),
        name: profile_name,
        access_token,
        uuid: profile_id.clone(),
        yggdrasil_server: Some(api_root),
        profile_id: Some(profile_id),
        expires_at: 0,
        refresh_token: None,
        client_token: if client_token.is_empty() { None } else { Some(client_token) },
        skin_url: None,
    };
    store::upsert_account(account.clone())?;
    Ok(account)
}

/// 令牌校验/续期，返回可用令牌（失败时抛错，由上层决定是否继续）
pub async fn yggdrasil_validate_or_refresh(
    api_root: String,
    access_token: String,
    client_token: String,
) -> Result<String> {
    let c = client()?;
    // validate
    let vresp = c
        .post(format!("{api_root}/authserver/validate"))
        .json(&json!({
            "accessToken": access_token,
            "clientToken": client_token,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("令牌校验失败: {e}"))?;
    if vresp.status().as_u16() == 204 {
        return Ok(access_token);
    }
    // refresh
    let rresp = c
        .post(format!("{api_root}/authserver/refresh"))
        .json(&json!({
            "accessToken": access_token,
            "clientToken": client_token,
            "requestUser": false,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("令牌续期失败: {e}"))?;
    let data: Value = rresp.json().await.unwrap_or(Value::Null);
    let new_token = data["accessToken"]
        .as_str()
        .ok_or_else(|| anyhow!("外置登录令牌已失效，请重新登录"))?
        .to_string();
    crate::log_info!("Auth", "外置令牌已自动续期");
    Ok(new_token)
}

// ---------------------------------------------------------------------------
// 微软登录（设备码流程）
// ---------------------------------------------------------------------------

/// 开源启动器通用的官方 Minecraft Launcher 公开客户端 ID
/// （MultiMC / PolyMC / Prism 同款，公开客户端无密钥）
pub const MS_CLIENT_ID: &str = "00000000402b5328";
const MS_DEVICE_CODE_URL: &str = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode";
const MS_TOKEN_URL: &str = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token";
const XBL_URL: &str = "https://user.auth.xboxlive.com/user/authenticate";
const XSTS_URL: &str = "https://xsts.auth.xboxlive.com/xsts/authorize";
const MC_LOGIN_URL: &str = "https://api.minecraftservices.com/authentication/login_with_xbox";
const MC_PROFILE_URL: &str = "https://api.minecraftservices.com/minecraft/profile";

/// 微软登录事件
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MsLoginEvent {
    /// device_code | polling | profile | done | failed
    pub step: String,
    pub message: String,
    /// 用户代码（device_code 阶段有效）
    pub user_code: String,
    /// 验证地址（device_code 阶段有效）
    pub verification_uri: String,
}

/// 发起微软设备码登录，事件经桥接发射器回传；返回已保存的账户。
pub async fn microsoft_login(em: &crate::bridge::Emitter) -> Result<Account> {
    let c = client()?;
    let emit = |step: &str, msg: &str, code: &str, uri: &str| {
        em.send(&MsLoginEvent {
            step: step.into(),
            message: msg.into(),
            user_code: code.into(),
            verification_uri: uri.into(),
        });
    };

    // 1. 设备码
    emit("device_code", "正在获取登录代码...", "", "");
    let resp = c
        .post(MS_DEVICE_CODE_URL)
        .form(&[
            ("client_id", MS_CLIENT_ID),
            ("scope", "XboxLive.signin offline_access"),
        ])
        .send()
        .await
        .map_err(|e| anyhow!("连接微软服务器失败: {e}"))?;
    let mut data: Value = resp.json().await.map_err(|e| anyhow!("解析设备码响应失败: {e}"))?;
    let device_code = data["device_code"]
        .as_str()
        .ok_or_else(|| anyhow!("微软未返回设备码"))?
        .to_string();
    let user_code = data["user_code"].as_str().unwrap_or("").to_string();
    let verify_uri = data["verification_uri"]
        .as_str()
        .unwrap_or("https://www.microsoft.com/link")
        .to_string();
    let interval = data["interval"].as_u64().unwrap_or(5).max(3);
    emit(
        "device_code",
        "请在浏览器打开验证地址并输入代码",
        &user_code,
        &verify_uri,
    );

    // 2. 轮询令牌
    emit("polling", "等待浏览器授权...", &user_code, &verify_uri);
    let access_token = loop {
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        let tres = c
            .post(MS_TOKEN_URL)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", MS_CLIENT_ID),
                ("device_code", device_code.as_str()),
            ])
            .send()
            .await
            .map_err(|e| anyhow!("轮询微软服务器失败: {e}"))?;
        let tdata: Value = tres.json().await.unwrap_or(Value::Null);
        let fresh = tdata["access_token"].as_str().map(|s| s.to_string());
        if let Some(tok) = fresh {
            data = tdata;
            break tok;
        }
        let error = tdata["error"].as_str().unwrap_or("");
        match error {
            "authorization_pending" => continue,
            "slow_down" => {
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                continue;
            }
            "authorization_expired" => bail!("登录代码已过期，请重新发起登录"),
            "cancelled" | "authorization_declined" => bail!("您取消了登录"),
            other => bail!("微软登录失败: {other}"),
        }
    };
    let refresh_token = data["refresh_token"].as_str().unwrap_or("").to_string();

    // 3. XBL → XSTS → Minecraft
    emit("profile", "正在获取档案...", "", "");
    let account = microsoft_flow_from_token(&c, &access_token, refresh_token).await?;
    emit("done", &format!("登录成功: {}", account.name), "", "");
    store::upsert_account(account.clone())?;
    Ok(account)
}

/// 用刷新令牌续期微软账户
pub async fn microsoft_refresh(refresh_token: String) -> Result<Account> {
    anyhow::ensure!(!refresh_token.is_empty(), "该账户没有刷新令牌，请重新登录");
    let c = client()?;
    let resp = c
        .post(MS_TOKEN_URL)
        .form(&[
            ("client_id", MS_CLIENT_ID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
            ("scope", "XboxLive.signin offline_access"),
        ])
        .send()
        .await
        .map_err(|e| anyhow!("刷新微软令牌失败: {e}"))?;
    let data: Value = resp.json().await.unwrap_or(Value::Null);
    let access = data["access_token"]
        .as_str()
        .ok_or_else(|| anyhow!("刷新失败（{}），请重新登录", data["error"].as_str().unwrap_or("unknown")))?
        .to_string();
    let refresh = data["refresh_token"].as_str().unwrap_or(&refresh_token).to_string();
    let account = microsoft_flow_from_token(&c, &access, refresh).await?;
    store::upsert_account(account.clone())?;
    Ok(account)
}

/// XBL → XSTS → MC Services → Profile 全链
async fn microsoft_flow_from_token(
    c: &reqwest::Client,
    ms_access_token: &str,
    refresh_token: String,
) -> Result<Account> {
    // XBL
    let xbl: Value = c
        .post(XBL_URL)
        .json(&json!({
            "Properties": {
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": format!("d={ms_access_token}"),
            },
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        }))
        .send()
        .await
        .map_err(|e| anyhow!("Xbox Live 认证失败: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("XBL 响应解析失败: {e}"))?;
    let xbl_token = xbl
        .pointer("/Token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("XBL 认证未返回令牌"))?
        .to_string();
    let uhs = xbl
        .pointer("/DisplayClaims/xui/0/uhs")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // XSTS
    let xsts: Value = c
        .post(XSTS_URL)
        .json(&json!({
            "Properties": {
                "SandboxId": "RETAIL",
                "UserTokens": [xbl_token],
            },
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT",
        }))
        .send()
        .await
        .map_err(|e| anyhow!("XSTS 认证失败: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("XSTS 响应解析失败: {e}"))?;
    let xsts_token = xsts
        .pointer("/Token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            let code = xsts
                .pointer("/XErr")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            match code {
                2148916233 => anyhow!("该微软账户没有 Xbox 档案，请先创建 Xbox 账户"),
                2148916238 => anyhow!("该账户是儿童账户，需要家长允许游玩"),
                _ => anyhow!("XSTS 认证未返回令牌 (XErr={code})"),
            }
        })?
        .to_string();
    let uhs = if uhs.is_empty() {
        xsts.pointer("/DisplayClaims/xui/0/uhs")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    } else {
        uhs
    };

    // Minecraft Services
    let mc: Value = c
        .post(MC_LOGIN_URL)
        .json(&json!({ "identityToken": format!("XBL3.0 x={uhs};{xsts_token}") }))
        .send()
        .await
        .map_err(|e| anyhow!("Minecraft 服务登录失败: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("MC 响应解析失败: {e}"))?;
    let mc_token = mc
        .pointer("/access_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("未拥有 Minecraft（Java 版）正版授权"))?
        .to_string();
    let expires_in = mc.pointer("/expires_in").and_then(|v| v.as_i64()).unwrap_or(86400);

    // Profile
    let profile_resp = c
        .get(MC_PROFILE_URL)
        .bearer_auth(&mc_token)
        .send()
        .await
        .map_err(|e| anyhow!("获取档案失败: {e}"))?;
    anyhow::ensure!(
        profile_resp.status().is_success(),
        "未拥有 Minecraft（Java 版）正版档案 (HTTP {})",
        profile_resp.status()
    );
    let profile: Value = profile_resp.json().await.unwrap_or(Value::Null);
    let name = profile["name"]
        .as_str()
        .ok_or_else(|| anyhow!("档案缺少玩家名"))?
        .to_string();
    let uuid = profile["id"].as_str().unwrap_or("").to_string();
    let skin_url = profile
        .pointer("/skins/0/url")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let account = Account {
        id: store::new_account_id(),
        account_type: "microsoft".into(),
        name,
        access_token: mc_token,
        uuid,
        yggdrasil_server: None,
        profile_id: None,
        expires_at: now_ms() + expires_in * 1000,
        refresh_token: if refresh_token.is_empty() { None } else { Some(refresh_token) },
        client_token: None,
        skin_url,
    };
    crate::log_info!("Auth", "微软登录成功: {}", account.name);
    Ok(account)
}

/// 微软令牌是否需要刷新（提前 60s）
pub fn microsoft_needs_refresh(account: &Account) -> bool {
    account.account_type == "microsoft"
        && account.expires_at > 0
        && now_ms() >= account.expires_at - 60_000
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

// ---------------------------------------------------------------------------
// authlib-injector（对齐 PCL：外置登录时注入）
// ---------------------------------------------------------------------------

/// 确保 authlib-injector.jar 就绪，返回 jar 路径（字符串）。
/// 位置固定：`exe 所在目录\FMCL\lib\authlib-injector\authlib-injector.jar`。
/// 已存在时直接使用；无网络且无本地文件时报错。
pub async fn ensure_authlib_injector() -> Result<String> {
    let dir = crate::core::paths::paths().authlib_injector_dir.clone();
    std::fs::create_dir_all(&dir)?;
    let jar = dir.join("authlib-injector.jar");
    let version_file = dir.join("version.txt");
    let local_version = std::fs::read_to_string(&version_file)
        .unwrap_or_default()
        .trim()
        .to_string();

    if jar.exists() && !local_version.is_empty() {
        crate::log_info!("Auth", "authlib-injector {local_version} 已就绪: {}", jar.display());
        return Ok(jar.to_string_lossy().into_owned());
    }

    crate::log_info!("Auth", "下载 authlib-injector → {}", jar.display());
    let c = client()?;
    // 源 1：官方 artifact 清单（带 SHA1 校验）
    let result = fetch_authlib_official(&c, &jar).await;
    match result {
        Ok(version) => {
            let _ = std::fs::write(&version_file, version);
            Ok(jar.to_string_lossy().into_owned())
        }
        Err(official_err) => {
            // 源 2：GitHub Releases 回退
            crate::log_warn!("Auth", "官方源失败（{official_err}），尝试 GitHub Releases");
            fetch_authlib_github(&c, &jar)
                .await
                .map(|version| {
                    let _ = std::fs::write(&version_file, version);
                    jar.to_string_lossy().into_owned()
                })
                .map_err(|gh_err| {
                    anyhow!("authlib-injector 下载失败（官方与 GitHub 均不可达）: {official_err} / {gh_err}")
                })
        }
    }
}

async fn fetch_authlib_official(c: &reqwest::Client, jar: &Path) -> Result<String> {
    let artifact: Value = c
        .get("https://authlib-injector.yushi.moe/artifact/latest.json")
        .send()
        .await
        .map_err(|e| anyhow!("官方清单不可达: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("官方清单解析失败: {e}"))?;
    let version = artifact["version"]
        .as_str()
        .ok_or_else(|| anyhow!("清单缺少版本号"))?
        .to_string();
    let url = artifact["url"]
        .as_str()
        .ok_or_else(|| anyhow!("清单缺少下载地址"))?
        .to_string();
    let sha1 = artifact
        .pointer("/checksums/sha1")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let bytes = c
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow!("下载失败: {e}"))?
        .error_for_status()?
        .bytes()
        .await
        .map_err(|e| anyhow!("读取下载内容失败: {e}"))?;
    if !sha1.is_empty() {
        use sha1::Digest;
        let actual = hex::encode(sha1::Sha1::digest(bytes.as_ref()));
        anyhow::ensure!(
            actual.eq_ignore_ascii_case(&sha1),
            "SHA1 校验失败（期望 {sha1}，实际 {actual}）"
        );
    }
    std::fs::write(jar, &bytes)?;
    crate::log_info!("Auth", "authlib-injector {version} 已就绪（{} 字节）", bytes.len());
    Ok(version)
}

async fn fetch_authlib_github(c: &reqwest::Client, jar: &Path) -> Result<String> {
    let release: Value = c
        .get("https://api.github.com/repos/yushijinhun/authlib-injector/releases/latest")
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|e| anyhow!("GitHub API 不可达: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("GitHub 响应解析失败: {e}"))?;
    let version = release["tag_name"]
        .as_str()
        .unwrap_or("unknown")
        .trim_start_matches('v')
        .to_string();
    let asset_url = release["assets"]
        .as_array()
        .and_then(|a| {
            a.iter()
                .find(|x| {
                    x["name"]
                        .as_str()
                        .map(|n| n.starts_with("authlib-injector-") && n.ends_with(".jar"))
                        .unwrap_or(false)
                })
                .and_then(|x| x["browser_download_url"].as_str())
        })
        .ok_or_else(|| anyhow!("GitHub Release 中未找到 jar 资产"))?
        .to_string();
    let bytes = c
        .get(&asset_url)
        .send()
        .await
        .map_err(|e| anyhow!("下载失败: {e}"))?
        .error_for_status()?
        .bytes()
        .await
        .map_err(|e| anyhow!("读取下载内容失败: {e}"))?;
    std::fs::write(jar, &bytes)?;
    crate::log_info!("Auth", "authlib-injector {version}（GitHub）已就绪");
    Ok(version)
}
