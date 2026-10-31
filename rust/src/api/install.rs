//! 合并安装管线：原版 + 加载器 + 高清修复（OptiFine）一体化安装。
//!
//! 行为对齐 PCL2「合并安装」的用户体验（临时装配 → 版本 JSON 合并 →
//! 支持库补全 → 落盘），实现为本项目原创 Rust 代码：
//!
//! 1. 原版：版本 JSON / 客户端 / 支持库 / 资源索引 + 资源文件
//! 2. Fabric / Quilt：Meta profile JSON 参与合并
//! 3. Forge / NeoForge：安装器解析 + 处理器链执行（支持断点续装）
//! 4. OptiFine（高清修复）：
//!    - 已选任意加载器时按「模组」放入 mods（安装器 jar 即模组 jar）
//!    - 纯原版时以 Tweaker 方式构造版本（不运行图形安装器）
//! 5. 版本 JSON 合并（minecraftArguments 恢复 / id 归一）
//! 6. 支持库与资源补全扫描
//!
//! 下载源：官方 / BMCLAPI 可切换，每个条目自带回退候选。

use crate::api::download::DownloadItem;
use crate::util::http::download_all;
use crate::api::hash::file_sha1;
use crate::util::cancel::CANCEL_REGISTRY;
use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;

type CancelFlag = Arc<std::sync::atomic::AtomicBool>;

/// 进度事件出口：FRB sink 与内部管线（整合包）共用的抽象。
/// 回调需 Send+Sync（在 await 链路中传递，不进入 'static spawn）。
pub(crate) type Emit<'a> = &'a (dyn Fn(InstallProgressEvent) + Send + Sync);

/// OptiFine（高清修复）条目
#[derive(Debug, Clone)]
pub struct OptiFineEntry {
    /// 继承的原版版本，如 "1.20.1"
    pub inherit: String,
    /// 显示名，如 "1.20.1 HD_U_I6"
    pub display_name: String,
    /// 官方文件名，如 "OptiFine_1.20.1_HD_U_I6.jar"
    pub file_name: String,
    pub is_preview: bool,
}

/// 合并安装请求
#[derive(Debug, Clone)]
pub struct InstallRequest {
    /// 游戏根目录（.minecraft）
    pub game_dir: String,
    /// 目标版本名（versions/<name>/）
    pub instance_name: String,
    /// 原版游戏版本
    pub game_version: String,
    /// 已知的版本 JSON 地址（None = 从清单检索）
    pub version_json_url: Option<String>,
    pub fabric_version: Option<String>,
    pub quilt_version: Option<String>,
    /// Forge 版本（"47.2.0"；兼容 "1.19.3-41.2.8" 样式自动拆分）
    pub forge_version: Option<String>,
    pub neoforge_version: Option<String>,
    /// 高清修复（OptiFine）
    pub optifine: Option<OptiFineEntry>,
    /// 处理器链用 Java 可执行文件（空 = 使用 PATH 中的 java）
    pub java_path: String,
    /// true = BMCLAPI 优先（默认）
    pub use_bmclapi: bool,
    pub concurrency: i32,
    /// 下载会话 id（支持取消）
    pub session_id: String,
}

/// 安装进度事件
#[derive(Debug, Clone)]
pub struct InstallProgressEvent {
    /// resolve | download | process | merge | finalize | done | failed | cancelled
    pub phase: String,
    pub message: String,
    /// 总进度 0.0 ~ 1.0
    pub progress: f64,
}

// ---------------------------------------------------------------------------
// 下载源
// ---------------------------------------------------------------------------

pub(crate) const OFFICIAL_MANIFEST: &str =
    "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json";
pub(crate) const BMCLAPI_ROOT: &str = "https://bmclapi2.bangbang93.com";
const OFFICIAL_LIBS: &str = "https://libraries.minecraft.net";
const OFFICIAL_RES: &str = "https://resources.download.minecraft.net";

pub(crate) fn map_to_bmclapi(url: &str) -> Option<String> {
    let mapped = if let Some(rest) = url
        .strip_prefix("https://launchermeta.mojang.com/")
        .or_else(|| url.strip_prefix("https://piston-meta.mojang.com/"))
        .or_else(|| url.strip_prefix("https://piston-data.mojang.com/"))
    {
        format!("{BMCLAPI_ROOT}/{rest}")
    } else if let Some(rest) = url.strip_prefix("https://libraries.minecraft.net/") {
        format!("{BMCLAPI_ROOT}/maven/{rest}")
    } else if let Some(rest) = url.strip_prefix("https://resources.download.minecraft.net/") {
        format!("{BMCLAPI_ROOT}/assets/{rest}")
    } else if let Some(rest) = url.strip_prefix("https://maven.minecraftforge.net/") {
        format!("{BMCLAPI_ROOT}/maven/{rest}")
    } else if let Some(rest) = url.strip_prefix("https://maven.neoforged.net/releases/") {
        format!("{BMCLAPI_ROOT}/maven/{rest}")
    } else {
        return None;
    };
    Some(mapped)
}

/// 生成 [首选, 回退…] 双源候选
pub(crate) fn dual_urls(url: &str, bmclapi_first: bool) -> Vec<String> {
    let alt = map_to_bmclapi(url);
    match (bmclapi_first, alt) {
        (true, Some(a)) => vec![a, url.to_string()],
        (false, Some(a)) => vec![url.to_string(), a],
        (_, None) => vec![url.to_string()],
    }
}

fn lib_url(path: &str, bmclapi_first: bool) -> Vec<String> {
    let official = format!("{OFFICIAL_LIBS}/{path}");
    let bmclapi = format!("{BMCLAPI_ROOT}/maven/{path}");
    if bmclapi_first {
        vec![bmclapi, official]
    } else {
        vec![official, bmclapi]
    }
}

fn asset_url(hash: &str, bmclapi_first: bool) -> Vec<String> {
    let official = format!("{OFFICIAL_RES}/{}/{}", &hash[..2], hash);
    let bmclapi = format!("{BMCLAPI_ROOT}/assets/{}/{}", &hash[..2], hash);
    if bmclapi_first {
        vec![bmclapi, official]
    } else {
        vec![official, bmclapi]
    }
}

async fn fetch_json(client: &reqwest::Client, urls: &[String]) -> Result<Value> {
    let mut last = String::new();
    for url in urls {
        let resp = client.get(url).send().await;
        match resp {
            Ok(r) if r.status().is_success() => match r.json::<Value>().await {
                Ok(v) => return Ok(v),
                Err(e) => last = format!("JSON 解析失败 {url}: {e}"),
            },
            Ok(r) => last = format!("HTTP {} {url}", r.status()),
            Err(e) => last = format!("{url}: {e}"),
        }
    }
    bail!("获取 JSON 失败: {last}")
}

pub(crate) async fn download_with_fallback(
    urls: &[String],
    save: &Path,
    sha1: Option<&str>,
    size: Option<i64>,
) -> Result<()> {
    let probe = DownloadItem {
        url: urls[0].clone(),
        save_path: save.to_string_lossy().into_owned(),
        expected_sha1: sha1.map(|s| s.to_string()),
        expected_size: size,
        alt_urls: vec![],
    };
    if verify_existing(&probe) {
        return Ok(());
    }
    let mut last = String::new();
    for url in urls {
        let item = DownloadItem {
            url: url.clone(),
            save_path: save.to_string_lossy().into_owned(),
            expected_sha1: sha1.map(|s| s.to_string()),
            expected_size: size,
            alt_urls: vec![],
        };
        let (ok, _failed) = download_all(
            std::slice::from_ref(&item),
            1,
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
            None,
            |_, _, _| {},
        )
        .await;
        if ok == 1 {
            return Ok(());
        }
        last = format!("url={url}");
    }
    bail!("下载失败: {last}")
}

pub(crate) fn verify_existing(item: &DownloadItem) -> bool {
    if !Path::new(&item.save_path).exists() {
        return false;
    }
    if item.expected_sha1.is_none() && item.expected_size.is_none() {
        return true;
    }
    if let Some(sha) = &item.expected_sha1 {
        match file_sha1(item.save_path.clone()) {
            Ok(actual) => {
                if !actual.eq_ignore_ascii_case(sha) {
                    return false;
                }
            }
            Err(_) => return false,
        }
    }
    true
}

// ---------------------------------------------------------------------------
// 进度
// ---------------------------------------------------------------------------

pub(crate) struct Progress<'a> {
    emit: Emit<'a>,
    cancelled: CancelFlag,
}

impl<'a> Progress<'a> {
    pub(crate) fn new(emit: Emit<'a>, cancelled: CancelFlag) -> Self {
        Self { emit, cancelled }
    }

    pub(crate) fn step(&self, phase: &str, message: &str, fraction: f64) {
        (self.emit)(InstallProgressEvent {
            phase: phase.into(),
            message: message.into(),
            progress: fraction.clamp(0.0, 1.0),
        });
    }

    pub(crate) fn check_cancel(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Relaxed) {
            (self.emit)(InstallProgressEvent {
                phase: "cancelled".into(),
                message: "安装已取消".into(),
                progress: 0.0,
            });
            bail!("已取消");
        }
        Ok(())
    }
}

/// 批次下载（带 100ms 节流进度）
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_batch(
    emit: Emit<'_>,
    cancelled: &CancelFlag,
    items: &[DownloadItem],
    from: f64,
    to: f64,
    concurrency: usize,
    label: &str,
) -> Result<()> {
    if items.is_empty() {
        return Ok(());
    }
    let total = items.len() as i32;
    let counter = Arc::new(std::sync::Mutex::new((0i32, std::time::Instant::now())));
    let counter_c = counter.clone();
    let (finished, failed) = download_all(items, concurrency, cancelled.clone(), None, {
        move |_ok, _item, _err| {
            let mut g = counter_c.lock().unwrap();
            g.0 += 1;
            let now = std::time::Instant::now();
            if now.duration_since(g.1).as_millis() >= 100 || g.0 >= total {
                g.1 = now;
                let frac = from + (to - from) * (g.0 as f64 / total as f64);
                emit(InstallProgressEvent {
                    phase: "download".into(),
                    message: format!("下载{label}（{}/{}）", g.0, total),
                    progress: frac.clamp(0.0, 1.0),
                });
            }
        }
    })
    .await;
    if cancelled.load(Ordering::Relaxed) {
        emit(InstallProgressEvent {
            phase: "cancelled".into(),
            message: "安装已取消".into(),
            progress: from,
        });
        bail!("已取消");
    }
    if failed > 0 {
        bail!("{label}下载失败：{failed}/{total} 个文件未完成");
    }
    emit(InstallProgressEvent {
        phase: "download".into(),
        message: format!("{label}下载完成（{finished}/{total}）"),
        progress: to,
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

/// 执行合并安装（FRB 接口，进度走事件流），返回最终版本 id。
pub async fn install_combined(
    request: InstallRequest,
    sink: crate::frb_generated::StreamSink<InstallProgressEvent>,
) -> Result<String> {
    install_combined_core(request, move |ev| {
        let _ = sink.add(ev);
    })
    .await
}

/// 内部核心安装管线（供整合包安装等内部调用方复用，进度走回调）。
pub(crate) async fn install_combined_core(
    request: InstallRequest,
    notify: impl Fn(InstallProgressEvent) + Send + Sync,
) -> Result<String> {
    if !CANCEL_REGISTRY.contains(&request.session_id) {
        CANCEL_REGISTRY.create(&request.session_id);
    }
    let cancelled = CANCEL_REGISTRY.handle(&request.session_id);
    let pg = Progress::new(&notify, cancelled.clone());
    let concurrency = request.concurrency.max(1) as usize;

    let result = run_pipeline(&request, &pg, &notify, concurrency, cancelled.clone()).await;
    match result {
        Ok(id) => {
            pg.step("done", &format!("安装完成：{id}"), 1.0);
            Ok(id)
        }
        Err(e) => {
            if e.to_string().contains("已取消") {
                Err(e)
            } else {
                notify(InstallProgressEvent {
                    phase: "failed".into(),
                    message: format!("安装失败: {e}"),
                    progress: 0.0,
                });
                Err(e)
            }
        }
    }
}

#[allow(clippy::too_many_lines)]
async fn run_pipeline(
    req: &InstallRequest,
    pg: &Progress<'_>,
    emit: Emit<'_>,
    concurrency: usize,
    cancelled: CancelFlag,
) -> Result<String> {
    let client = crate::util::http::build_public_client()?;
    let name = req.instance_name.trim().to_string();
    anyhow::ensure!(!name.is_empty(), "版本名不能为空");
    ensure_safe_name(&name)?;

    let game_dir = PathBuf::from(&req.game_dir);
    let version_dir = game_dir.join("versions").join(&name);
    if version_dir.join(format!("{name}.json")).exists() {
        bail!("版本 {name} 已存在，请更换名称");
    }
    std::fs::create_dir_all(&version_dir)?;

    // 装配临时目录（PCL2 式：先装配再落盘）
    let temp_root = game_dir.join(".fmcl-tmp").join(format!("install-{}", std::process::id()));
    let temp_version_dir = temp_root.join("versions").join(&name);
    std::fs::create_dir_all(&temp_version_dir)?;
    let temp_mods_dir = temp_root.join("mods");

    let outcome = async {
        // ---------- 1. 版本 JSON ----------
        pg.check_cancel()?;
        pg.step("resolve", "解析版本清单...", 0.02);
        let vanilla_json =
            load_vanilla_json(&client, req).await.context("获取原版版本 JSON 失败")?;
        std::fs::write(
            temp_version_dir.join(format!("{name}.json")),
            serde_json::to_vec_pretty(&vanilla_json)?,
        )?;
        pg.step("resolve", "版本定义就绪", 0.05);

        // ---------- 2. 客户端 jar ----------
        let client_info = vanilla_json
            .pointer("/downloads/client")
            .cloned()
            .ok_or_else(|| anyhow!("版本 {} 缺少客户端下载定义", req.game_version))?;
        let client_url = client_info["url"].as_str().unwrap_or_default().to_string();
        let client_sha = client_info["sha1"].as_str().map(|s| s.to_string());
        let client_size = client_info["size"].as_i64();
        let jar_path = temp_version_dir.join(format!("{name}.jar"));
        let bmcl_client = format!("{BMCLAPI_ROOT}/version/{}/client", req.game_version);
        let client_urls = if req.use_bmclapi {
            vec![bmcl_client, client_url]
        } else {
            vec![client_url, bmcl_client]
        };
        pg.step("download", "下载客户端...", 0.06);
        download_with_fallback(
            &client_urls,
            &jar_path,
            client_sha.as_deref(),
            client_size,
        )
        .await
        .context("客户端下载失败")?;
        pg.step("download", "客户端就绪", 0.10);

        // ---------- 3. 支持库 ----------
        let lib_items = collect_lib_items(vanilla_json.get("libraries"), &game_dir, req.use_bmclapi);
        run_batch(emit, &cancelled, &lib_items, 0.10, 0.24, concurrency, "支持库").await?;

        // ---------- 4. 资源 ----------
        let asset_items =
            collect_asset_items(&client, &vanilla_json, &game_dir, req.use_bmclapi).await?;
        run_batch(emit, &cancelled, &asset_items, 0.24, 0.44, concurrency, "资源文件").await?;

        // ---------- 5. 加载器 ----------
        let mut profiles: Vec<Value> = Vec::new();

        let forgelike = if let Some(v) = &req.neoforge_version {
            Some(("neoforge".to_string(), v.clone()))
        } else {
            req.forge_version.as_ref().map(|v| ("forge".to_string(), v.clone()))
        };
        if let Some((kind, ver)) = forgelike {
            pg.step("resolve", &format!("解析 {kind} 安装器..."), 0.45);
            let (profile_json, patched_jar) = install_forgelike(
                &client, req, pg, emit, kind, ver, &game_dir, &jar_path, &cancelled, concurrency,
            )
            .await?;
            profiles.push(profile_json);
            if let Some(patched) = patched_jar {
                std::fs::copy(&patched, &jar_path)
                    .map_err(|e| anyhow!("合并 Forge 补丁 jar 失败: {e}"))?;
            }
        }

        if let Some(v) = &req.fabric_version {
            let profile = fetch_json(
                &client,
                &[
                    format!("https://meta.fabricmc.net/v2/versions/loader/{}/{}/profile/json", req.game_version, v),
                    format!("{BMCLAPI_ROOT}/fabric-meta/v2/versions/loader/{}/{}/profile/json", req.game_version, v),
                ],
            )
            .await
            .context("获取 Fabric profile 失败")?;
            profiles.push(profile);
        }
        if let Some(v) = &req.quilt_version {
            let profile = fetch_json(
                &client,
                &[
                    format!("https://meta.quiltmc.org/v3/versions/loader/{}/{}/profile/json", req.game_version, v),
                ],
            )
            .await
            .context("获取 Quilt profile 失败")?;
            profiles.push(profile);
        }

        // ---------- 6. OptiFine（高清修复） ----------
        let has_loader = !profiles.is_empty();
        let mut optifine_profile: Option<Value> = None;
        if let Some(of) = &req.optifine {
            if of.inherit != req.game_version {
                bail!("高清修复 {} 与所选游戏版本 {} 不匹配", of.inherit, req.game_version);
            }
            pg.step("resolve", "下载高清修复（OptiFine）...", 0.82);
            let installer_path = temp_root.join("optifine-installer.jar");
            download_optifine_installer(&client, of, &installer_path).await?;
            if has_loader {
                // 按模组处理：安装器 jar 即模组 jar，放入 mods
                std::fs::create_dir_all(&temp_mods_dir)?;
                let mod_name = format!("OptiFine_{}.jar", of.display_name.replace(' ', "_"));
                std::fs::copy(&installer_path, temp_mods_dir.join(&mod_name))?;
                pg.step("resolve", "高清修复已按模组加入 mods", 0.84);
            } else {
                // Tweaker 方式构造（不运行图形安装器）
                optifine_profile = Some(install_optifine_standalone(of, &installer_path, &game_dir)?);
            }
            std::fs::remove_file(&installer_path).ok();
        }

        // ---------- 7. 合并版本 JSON ----------
        pg.step("merge", "合并版本定义...", 0.86);
        let mut sources: Vec<Value> = profiles.clone();
        if let Some(p) = optifine_profile {
            sources.push(p);
        }
        let merged = merge_version_jsons(&vanilla_json, &sources, &name);

        // ---------- 8. 补全扫描 ----------
        pg.step("resolve", "扫描待补全文件...", 0.88);
        let lib_items2 = collect_lib_items(merged.get("libraries"), &game_dir, req.use_bmclapi);
        let missing: Vec<DownloadItem> = lib_items2
            .into_iter()
            .filter(|it| !verify_existing(it))
            .collect();
        if !missing.is_empty() {
            run_batch(emit, &cancelled, &missing, 0.88, 0.96, concurrency, "补全支持库").await?;
        }

        // ---------- 9. 落盘 ----------
        pg.step("finalize", "写入版本文件...", 0.97);
        std::fs::write(
            version_dir.join(format!("{name}.json")),
            serde_json::to_vec_pretty(&merged)?,
        )?;
        std::fs::copy(&jar_path, version_dir.join(format!("{name}.jar")))?;
        if temp_mods_dir.exists() {
            let dest = version_dir.join("mods");
            std::fs::create_dir_all(&dest)?;
            copy_dir_recursive(&temp_mods_dir, &dest)?;
        }
        std::fs::create_dir_all(version_dir.join("resourcepacks"))?;
        Ok(name)
    }
    .await;

    std::fs::remove_dir_all(&temp_root).ok();
    if outcome.is_ok() {
        CANCEL_REGISTRY.dispose(&req.session_id);
    }
    outcome
}

// ---------------------------------------------------------------------------
// 原版 JSON
// ---------------------------------------------------------------------------

async fn load_vanilla_json(client: &reqwest::Client, req: &InstallRequest) -> Result<Value> {
    if let Some(url) = &req.version_json_url {
        return fetch_json(client, &dual_urls(url, req.use_bmclapi)).await;
    }
    let manifest_urls = if req.use_bmclapi {
        vec![
            format!("{BMCLAPI_ROOT}/mc/game/version_manifest_v2.json"),
            OFFICIAL_MANIFEST.to_string(),
        ]
    } else {
        vec![
            OFFICIAL_MANIFEST.to_string(),
            format!("{BMCLAPI_ROOT}/mc/game/version_manifest_v2.json"),
        ]
    };
    let manifest = fetch_json(client, &manifest_urls).await?;
    let entries = manifest["versions"]
        .as_array()
        .ok_or_else(|| anyhow!("版本清单格式异常"))?;
    let entry = entries
        .iter()
        .find(|e| e["id"].as_str() == Some(req.game_version.as_str()))
        .ok_or_else(|| anyhow!("版本清单中不存在 {}", req.game_version))?;
    let url = entry["url"]
        .as_str()
        .ok_or_else(|| anyhow!("版本条目缺少 url"))?
        .to_string();
    fetch_json(client, &dual_urls(&url, req.use_bmclapi)).await
}

// ---------------------------------------------------------------------------
// 支持库 / 资源收集
// ---------------------------------------------------------------------------

fn ensure_safe_name(name: &str) -> Result<()> {
    let bad = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    if name.chars().any(|c| bad.contains(&c)) || name == "." || name == ".." {
        bail!("版本名包含非法字符");
    }
    Ok(())
}

/// lib 规则评估（os / arch）——供 launch_api 复用
pub(crate) fn lib_allowed(lib: &Value, os_name: &str, arch: &str) -> bool {
    let Some(rules) = lib["rules"].as_array() else {
        return true;
    };
    if rules.is_empty() {
        return true;
    }
    let mut allowed = false;
    for rule in rules {
        let os = &rule["os"];
        let name_match = os["name"].as_str().map(|n| n == os_name).unwrap_or(true);
        let arch_match = os["arch"].as_str().map(|a| a == arch).unwrap_or(true);
        if !(name_match && arch_match) {
            continue;
        }
        match rule["action"].as_str() {
            Some("allow") => allowed = true,
            Some("disallow") => allowed = false,
            _ => {}
        }
    }
    allowed
}

fn current_os() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "osx"
    } else {
        "linux"
    }
}

fn native_classifier(os_name: &str) -> Option<&'static str> {
    match os_name {
        "windows" => Some("natives-windows"),
        "osx" => Some("natives-macos"),
        "linux" => Some("natives-linux"),
        _ => None,
    }
}

fn make_item(urls: Vec<String>, save: PathBuf, sha: Option<String>, size: Option<i64>) -> DownloadItem {
    DownloadItem {
        url: urls[0].clone(),
        save_path: save.to_string_lossy().into_owned(),
        expected_sha1: sha,
        expected_size: size,
        alt_urls: urls[1..].to_vec(),
    }
}

/// 客户端 jar 下载候选（官方 piston-data + BMCLAPI version 直链）
pub(crate) fn client_urls_for(client_info: &Value, bmclapi_first: bool) -> Vec<String> {
    let official = client_info["url"].as_str().unwrap_or_default().to_string();
    let bmcl_client = client_info["url"]
        .as_str()
        .and_then(|u| map_to_bmclapi(u))
        .unwrap_or_default();
    let mut urls = Vec::new();
    if bmclapi_first && !bmcl_client.is_empty() {
        urls.push(bmcl_client);
    }
    if !official.is_empty() {
        urls.push(official);
    }
    if !bmclapi_first && !bmcl_client.is_empty() {
        urls.push(bmcl_client);
    }
    urls
}

/// 从 libraries 数组构造下载清单
pub(crate) fn collect_lib_items(libs: Option<&Value>, game_dir: &Path, bmclapi_first: bool) -> Vec<DownloadItem> {
    let os_name = current_os();
    let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
    let libraries_dir = game_dir.join("libraries");
    let mut items = Vec::new();
    let Some(list) = libs.and_then(|l| l.as_array()) else {
        return items;
    };
    for lib in list {
        if !lib_allowed(lib, os_name, arch) {
            continue;
        }
        // 主 artifact
        let artifact = lib.pointer("/downloads/artifact");
        if let Some(art) = artifact {
            let path = art["path"].as_str().unwrap_or_default().to_string();
            let url = art["url"].as_str().unwrap_or_default().to_string();
            if !url.is_empty() && !path.is_empty() {
                items.push(make_item(
                    dual_urls(&url, bmclapi_first),
                    libraries_dir.join(&path),
                    art["sha1"].as_str().map(|s| s.to_string()),
                    art["size"].as_i64(),
                ));
            }
        } else if let Some(coord) = lib["name"].as_str() {
            // 无 downloads 元数据：由坐标 / lib.url 推导
            if let Some(rel) = coord_to_path(coord) {
                let base = lib["url"]
                    .as_str()
                    .map(|s| s.trim_end_matches('/').to_string());
                let urls = match base {
                    Some(b) => {
                        let full = format!("{b}/{rel}");
                        dual_urls(&full, bmclapi_first)
                    }
                    None => lib_url(&rel, bmclapi_first),
                };
                items.push(make_item(urls, libraries_dir.join(&rel), None, None));
            }
        }
        // natives
        if let Some(c) = native_classifier(os_name) {
            if let Some(nat) = lib
                .pointer(&format!("/downloads/classifiers/{c}"))
            {
                let path = nat["path"].as_str().unwrap_or_default().to_string();
                let url = nat["url"].as_str().unwrap_or_default().to_string();
                if !url.is_empty() && !path.is_empty() {
                    items.push(make_item(
                        dual_urls(&url, bmclapi_first),
                        libraries_dir.join(&path),
                        nat["sha1"].as_str().map(|s| s.to_string()),
                        nat["size"].as_i64(),
                    ));
                }
            }
        }
    }
    items
}

/// maven 坐标 → 相对路径（对外别名，launch_api 复用）
pub(crate) fn coord_to_path_pub(coord: &str) -> Option<String> {
    coord_to_path(coord)
}

/// maven 坐标 → 相对路径（group:artifact:version[:classifier][@ext]）
///
/// 支持 Forge 安装器的 @ext 记法：
/// - `de.oceanlabs.mcp:mcp_config:1.20.1-...@zip` → `.../mcp_config-1.20.1-....zip`
/// - `...:mcp_config:1.20.1-...:mappings@txt` → `.../mcp_config-...-mappings.txt`
fn coord_to_path(coord: &str) -> Option<String> {
    // 拆分 @ext 后缀（最后一个 @，ext 仅允许小写字母/数字，避免误伤含 @ 的怪异版本号）
    let (base, ext) = match coord.rsplit_once('@') {
        Some((b, e))
            if !e.is_empty()
                && e.len() <= 8
                && e.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()) =>
        {
            (b, e)
        }
        _ => (coord, "jar"),
    };
    let segs: Vec<&str> = base.split(':').collect();
    if segs.len() < 3 {
        return None;
    }
    let (g, a, v) = (segs[0], segs[1], segs[2]);
    let file = match segs.get(3) {
        Some(c) if !c.is_empty() => format!("{a}-{v}-{c}.{ext}"),
        _ => format!("{a}-{v}.{ext}"),
    };
    Some(format!("{}/{}/{}/{}", g.replace('.', "/"), a, v, file))
}

/// 资源索引 + 资源文件清单
pub(crate) async fn collect_asset_items(
    client: &reqwest::Client,
    vanilla_json: &Value,
    game_dir: &Path,
    bmclapi_first: bool,
) -> Result<Vec<DownloadItem>> {
    let index_ref = vanilla_json
        .pointer("/assetIndex")
        .ok_or_else(|| anyhow!("版本缺少 assetIndex"))?;
    let index_url = index_ref["url"].as_str().unwrap_or_default().to_string();
    let index_id = index_ref["id"].as_str().unwrap_or("legacy").to_string();
    let index_path = game_dir
        .join("assets")
        .join("indexes")
        .join(format!("{index_id}.json"));

    let index = fetch_json(client, &dual_urls(&index_url, bmclapi_first)).await?;
    let objects = index["objects"]
        .as_object()
        .ok_or_else(|| anyhow!("资源索引格式异常"))?;

    let mut items = Vec::new();
    if !index_path.exists() {
        items.push(make_item(
            dual_urls(&index_url, bmclapi_first),
            index_path,
            None,
            None,
        ));
    }
    let assets_dir = game_dir.join("assets").join("objects");
    for (_k, obj) in objects {
        let hash = obj["hash"].as_str().unwrap_or_default().to_string();
        if hash.len() < 4 {
            continue;
        }
        let save = assets_dir.join(&hash[..2]).join(&hash);
        if save.exists() {
            continue;
        }
        items.push(make_item(
            asset_url(&hash, bmclapi_first),
            save,
            Some(hash),
            obj["size"].as_i64(),
        ));
    }
    Ok(items)
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let target = dst.join(entry.file_name());
        if ty.is_dir() {
            std::fs::create_dir_all(&target)?;
            copy_dir_recursive(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Forge / NeoForge
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn install_forgelike(
    client: &reqwest::Client,
    req: &InstallRequest,
    pg: &Progress<'_>,
    emit: Emit<'_>,
    kind: String,
    version: String,
    game_dir: &Path,
    client_jar: &Path,
    cancelled: &CancelFlag,
    concurrency: usize,
) -> Result<(Value, Option<PathBuf>)> {
    let is_neo = kind == "neoforge";
    // 拆分 "1.19.3-41.2.8" 样式
    let (mc, loader_ver) = if !is_neo && version.contains('-') && version.starts_with("1.") {
        let mut it = version.splitn(2, '-');
        let m = it.next().unwrap_or("").to_string();
        let v = it.next().unwrap_or("").to_string();
        (m, v)
    } else {
        (req.game_version.clone(), version.clone())
    };

    // 下载安装器
    let installer_url = if is_neo {
        format!("https://maven.neoforged.net/releases/net/neoforged/neoforge/{loader_ver}/neoforge-{loader_ver}-installer.jar")
    } else {
        format!("https://maven.minecraftforge.net/net/minecraftforge/forge/{mc}-{v}/forge-{mc}-{v}-installer.jar",
            mc = mc.replace('-', "_"), v = loader_ver)
    };
    let installer_path = game_dir
        .join(".fmcl-tmp")
        .join(format!("{kind}-installer-{loader_ver}.jar"));
    std::fs::create_dir_all(installer_path.parent().unwrap())?;
    pg.step("download", &format!("下载 {kind} 安装器..."), 0.46);
    download_with_fallback(&dual_urls(&installer_url, req.use_bmclapi), &installer_path, None, None)
        .await?;

    // 解析 profile
    let path_str = installer_path.to_string_lossy().into_owned();
    let profile_bytes = crate::api::archive::read_zip_entry(
        path_str.clone(),
        "install_profile.json".into(),
    )
    .map_err(|_| anyhow!("{kind} 安装器缺少 install_profile.json（该版本可能暂不支持）"))?;
    let profile: Value = serde_json::from_slice(&profile_bytes)?;

    if !profile["processors"].is_array() {
        return install_forgelike_legacy(
            req, kind, mc, loader_ver, profile, &installer_path, game_dir,
            concurrency, cancelled,
        )
        .await;
    }

    // 现代（1.13+）
    let install_info = profile["install"].as_object().cloned().unwrap_or_default();
    let version_id = install_info
        .get("path")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("{mc}-{kind}-{loader_ver}"));
    let mc_version = install_info
        .get("minecraft")
        .and_then(|v| v.as_str())
        .unwrap_or(&mc)
        .to_string();

    let version_json: Option<Value> = match crate::api::archive::read_zip_entry(
        path_str.clone(),
        "version.json".into(),
    ) {
        Ok(b) => serde_json::from_slice(&b).ok(),
        Err(_) => None,
    };

    // 库下载（profile + version.json）
    let mut lib_items =
        collect_lib_items(profile.get("libraries"), game_dir, req.use_bmclapi);
    if let Some(vj) = &version_json {
        lib_items.extend(collect_lib_items(vj.get("libraries"), game_dir, req.use_bmclapi));
    }
    lib_items.retain(|it| !verify_existing(it));
    pg.step(
        "download",
        &format!("下载 {kind} 支持库（{}）...", lib_items.len()),
        0.50,
    );
    run_batch(emit, cancelled, &lib_items, 0.50, 0.58, concurrency, &format!("{kind} 支持库")).await?;

    // MOJMAPS 特例：从原版 client_mappings 下载映射
    if let Some(mojmaps) = profile.pointer("/data/MOJMAPS/client").and_then(|v| v.as_str()) {
        // 完整坐标（含 @txt 记法）直接交给 coord_to_path，
        // 保证与 resolve_profile_data / 处理器参数中的路径推导完全一致
        let coord = mojmaps.trim_matches(|c| c == '[' || c == ']');
        if let Some(rel) = coord_to_path(coord) {
            let save = game_dir.join("libraries").join(&rel);
            if !save.exists() {
                if let Ok(vanilla) = load_vanilla_json(client, req).await {
                    if let Some(cm) = vanilla.pointer("/downloads/client_mappings") {
                        let url = cm["url"].as_str().unwrap_or_default().to_string();
                        if !url.is_empty() {
                            download_with_fallback(
                                &dual_urls(&url, req.use_bmclapi),
                                &save,
                                cm["sha1"].as_str(),
                                cm["size"].as_i64(),
                            )
                            .await
                            .ok();
                        }
                    }
                }
            }
        }
    }

    // data 解析 + 处理器链
    let java = if req.java_path.is_empty() {
        if cfg!(target_os = "windows") { "javaw".to_string() } else { "java".to_string() }
    } else {
        req.java_path.clone()
    };
    let libraries_dir = game_dir.join("libraries");
    let bin_dir = game_dir.join("versions").join(&version_id).join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let data = resolve_profile_data(
        profile.get("data"),
        game_dir,
        &mc_version,
        &installer_path,
        &bin_dir,
        &version_id,
        client_jar,
    )?;
    run_processors(
        profile.get("processors"),
        &data,
        &libraries_dir,
        &java,
        emit,
        cancelled,
        0.58,
        0.78,
    )
    .await?;
    std::fs::remove_dir_all(&bin_dir).ok();

    // 处理器补丁产物 → 版本 jar（存在时）
    let patched = data
        .get("PATCHED")
        .map(PathBuf::from)
        .filter(|p| p.exists() && p != &client_jar.to_path_buf());

    let mut final_json = version_json.unwrap_or_else(|| {
        json!({
            "id": version_id,
            "inheritsFrom": mc_version,
            "mainClass": install_info.get("mainClass").cloned().unwrap_or(json!("")),
            "libraries": profile["libraries"].clone(),
        })
    });
    final_json["id"] = json!(version_id);
    std::fs::remove_file(&installer_path).ok();
    Ok((final_json, patched))
}

#[allow(clippy::too_many_arguments)]
async fn install_forgelike_legacy(
    req: &InstallRequest,
    kind: String,
    mc: String,
    loader_ver: String,
    profile: Value,
    installer_path: &Path,
    game_dir: &Path,
    concurrency: usize,
    cancelled: &CancelFlag,
) -> Result<(Value, Option<PathBuf>)> {
    let install = profile["install"].as_object().cloned().unwrap_or_default();
    let version_info = profile["versionInfo"].as_object().cloned().unwrap_or_default();
    if version_info.is_empty() {
        bail!("旧版安装器缺少 versionInfo");
    }
    let version_id = install
        .get("versionId")
        .and_then(|v| v.as_str())
        .unwrap_or(&format!("{mc}-{kind}-{loader_ver}"))
        .to_string();

    // universal jar
    if let Some(path_coord) = install.get("path").and_then(|v| v.as_str()) {
        if let Some(rel) = coord_to_path(path_coord) {
            let save = game_dir.join("libraries").join(&rel);
            download_with_fallback(&lib_url(&rel, req.use_bmclapi), &save, None, None).await?;
        }
    }
    let mut lib_items = collect_lib_items(
        Some(&Value::Object(version_info.clone())),
        game_dir,
        req.use_bmclapi,
    );
    lib_items.retain(|it| !verify_existing(it));
    if !lib_items.is_empty() {
        let (ok, failed) =
            download_all(&lib_items, concurrency, cancelled.clone(), None, |_, _, _| {}).await;
        if cancelled.load(Ordering::Relaxed) {
            bail!("已取消");
        }
        if ok < lib_items.len() as i32 {
            bail!("{kind} 旧版支持库下载失败（{failed}）");
        }
    }
    let mut final_json = Value::Object(version_info);
    final_json["id"] = json!(version_id);
    std::fs::remove_file(installer_path).ok();
    Ok((final_json, None))
}

/// install_profile.data 解析（{TOKEN} / [coord] / /安装器内条目）
#[allow(clippy::too_many_arguments)]
fn resolve_profile_data(
    data: Option<&Value>,
    game_dir: &Path,
    mc_version: &str,
    installer_path: &Path,
    bin_dir: &Path,
    version_id: &str,
    client_jar: &Path,
) -> Result<std::collections::HashMap<String, String>> {
    let mut known: std::collections::HashMap<String, String> = [
        ("SIDE".to_string(), "client".to_string()),
        ("MINECRAFT_VERSION".to_string(), mc_version.to_string()),
        ("ROOT".to_string(), game_dir.to_string_lossy().into_owned()),
        ("MINECRAFT_JAR".to_string(), client_jar.to_string_lossy().into_owned()),
        ("INSTALLER".to_string(), installer_path.to_string_lossy().into_owned()),
        ("LIBRARY_DIR".to_string(), game_dir.join("libraries").to_string_lossy().into_owned()),
        ("BIN".to_string(), bin_dir.to_string_lossy().into_owned()),
        ("OUTPUTS".to_string(), bin_dir.to_string_lossy().into_owned()),
        ("VERSION_ID".to_string(), version_id.to_string()),
    ]
    .into_iter()
    .collect();

    // 内置常量并入最终替换表（HMCL 同语义）：
    // Forge/NeoForge 处理器参数中的 {SIDE} {MINECRAFT_VERSION} {ROOT} 等可能
    // 不出现在 install_profile.data 里，必须由启动器提供。
    let mut resolved = known.clone();
    let Some(map) = data.and_then(|d| d.as_object()) else {
        return Ok(resolved);
    };
    for (key, value) in map {
        let side_value = value["client"]
            .as_str()
            .or_else(|| value["server"].as_str())
            .unwrap_or("")
            .to_string();
        let mut v = side_value;
        for (k, val) in &known {
            v = v.replace(&format!("{{{k}}}"), val);
        }
        if v.starts_with('[') && v.ends_with(']') {
            let coord = &v[1..v.len() - 1];
            if let Some(rel) = coord_to_path(coord) {
                v = game_dir.join("libraries").join(rel).to_string_lossy().into_owned();
            }
        } else if v.starts_with('/') {
            // 安装器内条目 → 解压到 bin
            let entry = v.trim_start_matches('/');
            let target = bin_dir.join(entry.rsplit('/').next().unwrap_or(entry));
            let bytes = crate::api::archive::read_zip_entry(
                installer_path.to_string_lossy().into_owned(),
                entry.to_string(),
            )?;
            std::fs::create_dir_all(target.parent().unwrap())?;
            std::fs::write(&target, bytes)?;
            v = target.to_string_lossy().into_owned();
        }
        known.insert(key.clone(), v.clone());
        resolved.insert(key.clone(), v);
    }
    // 二次展开（data 内部互相引用）
    let keys: Vec<String> = resolved.keys().cloned().collect();
    for key in keys {
        let mut v = resolved[&key].clone();
        for (k, val) in &known {
            v = v.replace(&format!("{{{k}}}"), val);
        }
        resolved.insert(key, v);
    }
    Ok(resolved)
}

#[allow(clippy::too_many_arguments)]
async fn run_processors(
    processors: Option<&Value>,
    data: &std::collections::HashMap<String, String>,
    libraries_dir: &Path,
    java: &str,
    emit: Emit<'_>,
    cancelled: &CancelFlag,
    from: f64,
    to: f64,
) -> Result<()> {
    let Some(list) = processors.and_then(|p| p.as_array()) else {
        return Ok(());
    };
    let client_side: Vec<&Value> = list
        .iter()
        .filter(|p| {
            let sides = p["sides"].as_array();
            match sides {
                None => true,
                Some(s) => s.iter().any(|x| x.as_str() == Some("client")),
            }
        })
        .collect();
    let total = client_side.len();
    for (i, proc_def) in client_side.iter().enumerate() {
        if cancelled.load(Ordering::Relaxed) {
            bail!("已取消");
        }
        let main_coord = proc_def["jar"].as_str().unwrap_or_default();
        let label = main_coord.split(':').nth(1).unwrap_or(main_coord);
        let _ = emit(InstallProgressEvent {
            phase: "process".into(),
            message: format!("执行处理器 {}/{}: {label}", i + 1, total),
            progress: from + (to - from) * (i as f64 / total.max(1) as f64),
        });

        // 输出校验 → 断点续装
        let outputs = proc_def["outputs"].as_object();
        if let Some(outputs) = outputs {
            let mut all_valid = true;
            for (key, sha) in outputs {
                let Some(path) = resolve_output_path(key, data, libraries_dir) else {
                    all_valid = false;
                    break;
                };
                if !path.exists() {
                    all_valid = false;
                    break;
                }
                match file_sha1(path.to_string_lossy().into_owned()) {
                    Ok(actual) => {
                        if !actual.eq_ignore_ascii_case(sha.as_str().unwrap_or_default()) {
                            all_valid = false;
                            break;
                        }
                    }
                    Err(_) => {
                        all_valid = false;
                        break;
                    }
                }
            }
            if all_valid {
                continue; // 输出已存在且校验通过
            }
        }

        // 主类（读处理器 jar MANIFEST）
        let main_jar = libraries_dir.join(
            coord_to_path(main_coord).ok_or_else(|| anyhow!("非法处理器坐标 {main_coord}"))?,
        );
        anyhow::ensure!(main_jar.exists(), "处理器 jar 缺失: {main_coord}");
        let main_class = read_main_class(&main_jar)?;
        anyhow::ensure!(main_class.is_some(), "处理器 jar 缺少 Main-Class: {main_coord}");

        // classpath
        let sep = if cfg!(target_os = "windows") { ";" } else { ":" };
        let mut cp = vec![main_jar.to_string_lossy().into_owned()];
        if let Some(classpath) = proc_def["classpath"].as_array() {
            for c in classpath {
                let coord = c.as_str().unwrap_or_default();
                if let Some(rel) = coord_to_path(coord) {
                    cp.push(libraries_dir.join(rel).to_string_lossy().into_owned());
                }
            }
        }

        // 参数 token 替换
        let mut args: Vec<String> = Vec::new();
        if let Some(raw) = proc_def["args"].as_array() {
            for a in raw {
                let mut s = a.as_str().unwrap_or("").to_string();
                for (k, val) in data {
                    s = s.replace(&format!("{{{k}}}"), val);
                }
                s = replace_maven_coords(&s, libraries_dir);
                args.push(s);
            }
        }

        let output = tokio::process::Command::new(java)
            .arg("-cp")
            .arg(cp.join(sep))
            .arg(main_class.unwrap())
            .args(&args)
            .output()
            .await
            .map_err(|e| anyhow!("运行处理器失败 ({java}): {e}"))?;
        if !output.status.success() {
            bail!(
                "处理器执行失败 {main_coord}: exit={:?}\nstdout: {}\nstderr: {}",
                output.status.code(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        // 运行后输出校验
        if let Some(outputs) = outputs {
            for key in outputs.keys() {
                let path = resolve_output_path(key, data, libraries_dir)
                    .ok_or_else(|| anyhow!("处理器输出路径无法解析: {key}"))?;
                anyhow::ensure!(path.exists(), "处理器输出缺失: {key}");
            }
        }
    }
    Ok(())
}

fn resolve_output_path(
    key: &str,
    data: &std::collections::HashMap<String, String>,
    libraries_dir: &Path,
) -> Option<PathBuf> {
    if let Some(v) = data.get(key) {
        return Some(PathBuf::from(v));
    }
    if key.starts_with('[') && key.ends_with(']') {
        let rel = coord_to_path(&key[1..key.len() - 1])?;
        return Some(libraries_dir.join(rel));
    }
    Some(PathBuf::from(key))
}

fn replace_maven_coords(input: &str, libraries_dir: &Path) -> String {
    let mut out = String::with_capacity(input.len());
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'[' {
            if let Some(end) = input[i + 1..].find(']') {
                let coord = &input[i + 1..i + 1 + end];
                if let Some(rel) = coord_to_path(coord) {
                    out.push_str(&libraries_dir.join(rel).to_string_lossy());
                    i += end + 2;
                    continue;
                }
            }
        }
        // 按字符推进（UTF-8 安全：单字节 ASCII 判断已足够，中括号为 ASCII）
        let ch_len = utf8_len(bytes[i]);
        out.push_str(&input[i..i + ch_len]);
        i += ch_len;
    }
    out
}

fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

fn read_main_class(jar: &Path) -> Result<Option<String>> {
    let bytes = crate::api::archive::read_zip_entry(
        jar.to_string_lossy().into_owned(),
        "META-INF/MANIFEST.MF".into(),
    )?;
    let text = String::from_utf8_lossy(&bytes);
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("Main-Class:") {
            return Ok(Some(rest.trim().to_string()));
        }
    }
    Ok(None)
}

// ---------------------------------------------------------------------------
// OptiFine（高清修复）
// ---------------------------------------------------------------------------

/// 从 OptiFine 官方文件名解析 BMCLAPI 直链
/// "OptiFine_1.14_HD_U_F1_pre6.jar" → /optifine/1.14/HD_U_F1/pre6
fn optifine_bmcl_url(file_name: &str) -> Option<String> {
    let core = file_name
        .trim_end_matches(".jar")
        .trim_start_matches("preview_")
        .trim_start_matches("OptiFine_");
    let parts: Vec<&str> = core.split('_').collect();
    if parts.len() < 3 {
        return None;
    }
    let mc = parts[0];
    let patch = parts[parts.len() - 1];
    let typ = parts[1..parts.len() - 1].join("_");
    Some(format!("{BMCLAPI_ROOT}/optifine/{mc}/{typ}/{patch}"))
}

async fn download_optifine_installer(
    client: &reqwest::Client,
    of: &OptiFineEntry,
    save: &Path,
) -> Result<()> {
    // BMCLAPI 直链：/optifine/<mc>/<type>/<patch>（由官方文件名解析）
    let bmcl_url = optifine_bmcl_url(&of.file_name)
        .unwrap_or_else(|| format!("{BMCLAPI_ROOT}/optifine/{}", of.inherit));
    let item = DownloadItem {
        url: bmcl_url,
        save_path: save.to_string_lossy().into_owned(),
        expected_sha1: None,
        expected_size: None,
        alt_urls: vec![],
    };
    let (ok, _) = download_all(
        std::slice::from_ref(&item),
        1,
        Arc::new(std::sync::atomic::AtomicBool::new(false)),
        None,
        |_, _, _| {},
    )
    .await;
    if ok == 1 && std::fs::metadata(save).map(|m| m.len() > 100_000).unwrap_or(false) {
        return Ok(());
    }
    // 官方回退：解析 adloadx 页面
    let official_page = format!("https://optifine.net/adloadx?f={}", of.file_name);
    let page = client
        .get(&official_page)
        .header("Accept", "text/html")
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let link = page
        .split("downloadx?f=")
        .nth(1)
        .map(|rest| {
            let end = rest.find(['"', '\'']).unwrap_or(rest.len());
            &rest[..end]
        })
        .ok_or_else(|| anyhow!("OptiFine 官方下载地址解析失败"))?;
    let real = format!("https://optifine.net/downloadx?f={link}");
    download_with_fallback(&[real], save, None, None)
        .await
        .context("OptiFine 下载失败（BMCLAPI 与官方源均失败）")
}

/// 纯原版 + OptiFine：Tweaker 方式构造版本（不运行图形安装器）。
fn install_optifine_standalone(
    of: &OptiFineEntry,
    installer_path: &Path,
    game_dir: &Path,
) -> Result<Value> {
    let ver_name = of
        .file_name
        .trim_end_matches(".jar")
        .trim_start_matches("OptiFine_")
        .trim_start_matches("preview_")
        .to_string();

    // 1. 安装器 jar → optifine 库（安装器 jar 本身即 OptiFine 模组 jar）
    let lib_rel = format!("optifine/OptiFine/{ver_name}/OptiFine-{ver_name}.jar");
    let lib_path = game_dir.join("libraries").join(&lib_rel);
    std::fs::create_dir_all(lib_path.parent().unwrap())?;
    std::fs::copy(installer_path, &lib_path)?;

    // 2. launchwrapper：现代安装器内嵌 launchwrapper-of，旧版用公共 1.12
    let mut libs = vec![json!({ "name": format!("optifine:OptiFine:{ver_name}") })];
    let path_str = installer_path.to_string_lossy().into_owned();
    match crate::api::archive::read_zip_entry(path_str.clone(), "launchwrapper-of.txt".into()) {
        Ok(bytes) => {
            let lw_ver = String::from_utf8_lossy(&bytes).trim().to_string();
            let jar_name = format!("launchwrapper-of-{lw_ver}.jar");
            let lw_bytes =
                crate::api::archive::read_zip_entry(path_str, jar_name.clone())?;
            let rel = format!("launchwrapper-of/{lw_ver}/{jar_name}");
            let target = game_dir.join("libraries").join(&rel);
            std::fs::create_dir_all(target.parent().unwrap())?;
            std::fs::write(&target, lw_bytes)?;
            libs.push(json!({ "name": format!("launchwrapper-of:{lw_ver}") }));
        }
        Err(_) => {
            libs.push(json!({ "name": "net.minecraft:launchwrapper:1.12" }));
        }
    }

    // 3. 构造参与合并的 profile（id 由合并阶段统一覆盖）
    Ok(json!({
        "mainClass": "net.minecraft.launchwrapper.Launch",
        "arguments": { "game": ["--tweakClass", "optifine.OptiFineTweaker"] },
        "minecraftArguments": "--tweakClass optifine.OptiFineTweaker",
        "libraries": libs,
    }))
}

// ---------------------------------------------------------------------------
// 版本 JSON 合并（PCL2 式：参数恢复 + id 归一）
// ---------------------------------------------------------------------------

fn merge_version_jsons(base: &Value, others: &[Value], version_id: &str) -> Value {
    let mut merged = base.clone();
    // 收集全部 minecraftArguments（避免合并时原版参数被覆盖）
    let mut all_args = String::new();
    for (i, src) in std::iter::once(base).chain(others.iter()).enumerate() {
        if let Some(s) = src["minecraftArguments"].as_str() {
            if !all_args.is_empty() {
                all_args.push(' ');
            }
            let _ = i;
            all_args.push_str(s);
        }
    }
    for other in others {
        deep_merge(&mut merged, other);
    }

    // minecraftArguments 恢复：标志位配对去重
    if !all_args.trim().is_empty() {
        let mut parts: Vec<String> = Vec::new();
        for token in all_args.split_whitespace() {
            if !token.starts_with('-') {
                if let Some(last) = parts.last_mut() {
                    if last.starts_with('-') && !last.contains(' ') {
                        last.push(' ');
                        last.push_str(token);
                        continue;
                    }
                }
            }
            parts.push(token.to_string());
        }
        let mut seen = std::collections::HashSet::new();
        let joined: Vec<String> = parts
            .into_iter()
            .filter(|p| seen.insert(p.clone()))
            .collect();
        merged["minecraftArguments"] = json!(joined.join(" "));
    }

    if let Some(obj) = merged.as_object_mut() {
        obj.remove("_comment_");
        obj.remove("inheritsFrom");
        obj.remove("jar");
        obj.insert("id".into(), json!(version_id));
    }
    merged
}

/// 深合并：对象递归，数组拼接
fn deep_merge(base: &mut Value, other: &Value) {
    match (base, other) {
        (Value::Object(b), Value::Object(o)) => {
            for (k, v) in o {
                match b.get_mut(k) {
                    Some(existing) => deep_merge(existing, v),
                    None => {
                        b.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        (Value::Array(b), Value::Array(o)) => {
            for v in o {
                b.push(v.clone());
            }
        }
        (b, o) => {
            if !o.is_null() {
                *b = o.clone();
            }
        }
    }
}
