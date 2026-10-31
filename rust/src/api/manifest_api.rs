//! 远程版本清单与加载器版本列表 API。
//!
//! 数据源（按下载源设置自动镜像回退）：
//! - 原版：launchermeta / BMCLAPI（version_manifest_v2）
//! - Forge：BMCLAPI forge 列表（含 recommended 标记）→ 官方 promotions 兜底
//! - NeoForge：maven metadata（BMCLAPI maven 镜像优先）
//! - Fabric：meta.fabricmc.net（BMCLAPI fabric-meta 镜像优先）
//! - Quilt：meta.quiltmc.org
//! - OptiFine：BMCLAPI versionList（官方 adloadx 无列表 API）

use anyhow::{anyhow, Result};
use serde_json::Value;
use std::path::PathBuf;

pub const BMCLAPI_ROOT: &str = "https://bmclapi2.bangbang93.com";
pub const OFFICIAL_MANIFEST: &str = "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json";

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(12))
        .read_timeout(std::time::Duration::from_secs(45))
        .timeout(std::time::Duration::from_secs(90))
        .user_agent("FMCL/0.1.0 (github.com/Ming-QWQ520/FMCL)")
        .build()?)
}

async fn fetch_json_any(client: &reqwest::Client, urls: &[String]) -> Result<Value> {
    let mut last = String::new();
    for url in urls {
        match client.get(url).send().await {
            Ok(r) if r.status().is_success() => match r.json::<Value>().await {
                Ok(v) => return Ok(v),
                Err(e) => last = format!("JSON 解析失败 {url}: {e}"),
            },
            Ok(r) => last = format!("HTTP {} {url}", r.status()),
            Err(e) => last = format!("{url}: {e}"),
        }
    }
    Err(anyhow!("获取数据失败: {last}"))
}

async fn fetch_text_any(client: &reqwest::Client, urls: &[String]) -> Result<String> {
    let mut last = String::new();
    for url in urls {
        match client.get(url).send().await {
            Ok(r) if r.status().is_success() => match r.text().await {
                Ok(t) => return Ok(t),
                Err(e) => last = format!("读取失败 {url}: {e}"),
            },
            Ok(r) => last = format!("HTTP {} {url}", r.status()),
            Err(e) => last = format!("{url}: {e}"),
        }
    }
    Err(anyhow!("获取数据失败: {last}"))
}

// ---------------------------------------------------------------------------
// 原版清单
// ---------------------------------------------------------------------------

/// 远程原版版本条目
#[derive(Debug, Clone)]
pub struct RemoteVersionEntry {
    pub id: String,
    /// release / snapshot / old_beta / old_alpha
    pub version_type: String,
    /// 发布时间（ISO8601）
    pub release_time: String,
    pub url: String,
    /// 数据来源："bmclapi" | "official"
    pub source: String,
}

/// 获取原版版本清单（带 10 分钟磁盘缓存）
pub async fn fetch_remote_versions(bmclapi_first: bool) -> Result<Vec<RemoteVersionEntry>> {
    let cache = PathBuf::from(crate::core::paths::paths().cache_dir.join("version_manifest.json"));
    if let Ok(meta) = std::fs::metadata(&cache) {
        if let Ok(modified) = meta.modified() {
            if let Ok(age) = modified.elapsed() {
                if age.as_secs() < 600 {
                    if let Ok(text) = std::fs::read_to_string(&cache) {
                        if let Ok(v) = serde_json::from_str::<Value>(&text) {
                            if let Some(list) = parse_manifest(&v) {
                                return Ok(list);
                            }
                        }
                    }
                }
            }
        }
    }

    let bmcl = format!("{BMCLAPI_ROOT}/mc/game/version_manifest_v2.json");
    let urls: Vec<String> = if bmclapi_first {
        vec![bmcl, OFFICIAL_MANIFEST.into()]
    } else {
        vec![OFFICIAL_MANIFEST.into(), bmcl]
    };
    let json = fetch_json_any(&client()?, &urls).await?;
    let source = if json.as_object().is_some() {
        // 通过首个条目 url host 判断来源
        let first_url = json
            .pointer("/versions/0/url")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if first_url.contains("bmclapi") {
            "bmclapi"
        } else {
            "official"
        }
    } else {
        "official"
    };
    let list = parse_manifest(&json).ok_or_else(|| anyhow!("版本清单格式异常"))?;
    // 缓存
    if let Some(dir) = cache.parent() {
        let _ = std::fs::create_dir_all(dir);
        let _ = std::fs::write(&cache, serde_json::to_vec(&json).unwrap_or_default());
    }
    let _ = source;
    Ok(list)
}

fn parse_manifest(json: &Value) -> Option<Vec<RemoteVersionEntry>> {
    let arr = json["versions"].as_array()?;
    let list = arr
        .iter()
        .filter_map(|e| {
            Some(RemoteVersionEntry {
                id: e["id"].as_str()?.to_string(),
                version_type: e["type"].as_str().unwrap_or("release").to_string(),
                release_time: e["releaseTime"].as_str().unwrap_or("").to_string(),
                url: e["url"].as_str().unwrap_or("").to_string(),
                source: String::new(),
            })
        })
        .collect();
    Some(list)
}

// ---------------------------------------------------------------------------
// 加载器列表
// ---------------------------------------------------------------------------

/// 加载器版本条目
#[derive(Debug, Clone)]
pub struct LoaderVersionInfo {
    /// 显示/传给安装的版本号
    pub version: String,
    /// 是否推荐/稳定
    pub is_recommended: bool,
    /// 是否测试版（OptiFine preview / fabric beta）
    pub is_preview: bool,
}

/// 加载器种类：vanilla / forge / neoforge / fabric / quilt / optifine
pub async fn fetch_loader_versions(
    loader: String,
    mc_version: String,
    bmclapi_first: bool,
) -> Result<Vec<LoaderVersionInfo>> {
    let c = client()?;
    match loader.as_str() {
        "vanilla" => Ok(Vec::new()),
        "fabric" => {
            let meta = format!("https://meta.fabricmc.net/v2/versions/loader");
            let bmcl = format!("{BMCLAPI_ROOT}/fabric-meta/v2/versions/loader");
            let urls: Vec<String> = if bmclapi_first { vec![bmcl, meta] } else { vec![meta, bmcl] };
            let json = fetch_json_any(&c, &urls).await?;
            let arr = json.as_array().ok_or_else(|| anyhow!("Fabric 列表格式异常"))?;
            Ok(arr
                .iter()
                .filter_map(|e| {
                    let v = e["version"].as_str()?.to_string();
                    let stable = e["stable"].as_bool().unwrap_or(false);
                    Some(LoaderVersionInfo {
                        version: v,
                        is_recommended: stable,
                        is_preview: !stable,
                    })
                })
                .take(60)
                .collect())
        }
        "quilt" => {
            let json = fetch_json_any(
                &c,
                &["https://meta.quiltmc.org/v3/versions/loader".to_string()],
            )
            .await?;
            let arr = json.as_array().ok_or_else(|| anyhow!("Quilt 列表格式异常"))?;
            Ok(arr
                .iter()
                .filter_map(|e| {
                    let v = e["version"].as_str()?.to_string();
                    Some(LoaderVersionInfo {
                        version: v,
                        is_recommended: e["stable"].as_bool().unwrap_or(false),
                        is_preview: false,
                    })
                })
                .take(40)
                .collect())
        }
        "forge" => {
            // BMCLAPI：/forge/minecraft/<mc> → [{version, build, ...}]（推荐版含 recommended 字段由 promotions 判断）
            let bmcl_url = format!("{BMCLAPI_ROOT}/forge/minecraft/{mc_version}");
            let list = match fetch_json_any(&c, &[bmcl_url]).await {
                Ok(v) => v,
                Err(_) => {
                    // 官方兜底：promotions_slim（仅 latest/recommended）+ maven metadata
                    let promo = fetch_json_any(
                        &c,
                        &["https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json".to_string()],
                    )
                    .await
                    .unwrap_or(Value::Null);
                    let recommended = promo.pointer("/promos/1.20.1-recommended")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if recommended.is_empty() {
                        return Err(anyhow!("获取 Forge 版本列表失败（官方与镜像均不可达）"));
                    }
                    return Ok(vec![LoaderVersionInfo {
                        version: recommended,
                        is_recommended: true,
                        is_preview: false,
                    }]);
                }
            };
            let arr = list.as_array().ok_or_else(|| anyhow!("Forge 列表格式异常"))?;
            // 推荐版本号来自 promotions
            let recommended = fetch_json_any(
                &c,
                &["https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json".to_string()],
            )
            .await
            .ok()
            .and_then(|p| {
                p.pointer(&format!("/promos/{mc_version}-recommended"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            });
            Ok(arr
                .iter()
                .filter_map(|e| {
                    let v = e["version"].as_str()?.to_string();
                    Some(LoaderVersionInfo {
                        is_recommended: recommended.as_deref() == Some(v.as_str()),
                        version: v,
                        is_preview: false,
                    })
                })
                .collect())
        }
        "neoforge" => {
            let official = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml";
            let mirror = format!("{BMCLAPI_ROOT}/maven/net/neoforged/neoforge/maven-metadata.xml");
            let urls: Vec<String> = if bmclapi_first {
                vec![mirror, official.into()]
            } else {
                vec![official.into(), mirror]
            };
            let xml = fetch_text_any(&c, &urls).await?;
            let versions = parse_maven_versions(&xml);
            // 过滤当前 MC 的 NeoForge 线
            let prefix = if mc_version == "1.20.1" {
                "47.".to_string()
            } else {
                // 1.20.4 → "20.4." ; 1.21.1 → "21."
                let minor: Vec<&str> = mc_version.split('.').collect();
                if minor.len() >= 3 {
                    format!("{}.{}.", minor[1], minor[2])
                } else if minor.len() == 2 {
                    format!("{}.", minor[1])
                } else {
                    String::new()
                }
            };
            Ok(versions
                .into_iter()
                .filter(|v| v.starts_with(&prefix) && !v.contains('-'))
                .map(|v| LoaderVersionInfo {
                    version: v,
                    is_recommended: false,
                    is_preview: false,
                })
                .rev()
                .take(80)
                .collect())
        }
        "optifine" => {
            let json = fetch_json_any(
                &c,
                &[format!("{BMCLAPI_ROOT}/optifine/versionList")],
            )
            .await?;
            let arr = json.as_array().ok_or_else(|| anyhow!("OptiFine 列表格式异常"))?;
            Ok(arr
                .iter()
                .filter(|e| e["mcversion"].as_str() == Some(mc_version.as_str()))
                .map(|e| {
                    let typ = e["type"].as_str().unwrap_or("HD_U");
                    let patch = e["patch"].as_str().unwrap_or("");
                    let preview = e["is_preview"].as_bool().unwrap_or(false);
                    LoaderVersionInfo {
                        version: format!("{typ}_{patch}"),
                        is_recommended: false,
                        is_preview,
                    }
                })
                .collect())
        }
        _ => Err(anyhow!("未知加载器: {loader}")),
    }
}

/// 解析 maven-metadata.xml 的 <version> 列表
fn parse_maven_versions(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<version>") {
        let after = &rest[start + 9..];
        if let Some(end) = after.find("</version>") {
            out.push(after[..end].to_string());
            rest = &after[end + 10..];
        } else {
            break;
        }
    }
    out
}
