//! 本地版本管理 API：扫描 / 导入 / 删除 / 重命名 / 补全。
//!
//! 行为对齐 PCL2「版本管理」：
//! - 扫描 versions/ 下含 `<id>.json` 的目录为有效版本
//! - 识别加载器类型（forge/fabric/quilt/neoforge/optifine）与继承的原版
//! - 导入外部版本（复制 json+jar+依赖目录）
//! - 补全：客户端 jar / 支持库 / 资源索引+资源文件 / 日志配置（流式进度）

use crate::api::install::{
    collect_asset_items, collect_lib_items, client_urls_for, download_with_fallback, run_batch,
    verify_existing, Progress,
};
use crate::api::install::{InstallProgressEvent, BMCLAPI_ROOT};
use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Sink = crate::frb_generated::StreamSink<InstallProgressEvent>;
type CancelFlag = Arc<std::sync::atomic::AtomicBool>;

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// 本地版本信息
#[derive(Debug, Clone)]
pub struct LocalVersionInfo {
    pub id: String,
    pub dir: String,
    pub has_jar: bool,
    /// vanilla / forge / neoforge / fabric / quilt / optifine / unknown
    pub loader: String,
    /// 加载器版本（如 47.2.0），原版为空
    pub loader_version: String,
    /// 继承的原版版本（读取链根）
    pub game_version: String,
    /// 目录修改时间（毫秒）
    pub modified_ms: i64,
    /// 版本目录大小（字节，含 jar）
    pub size_bytes: i64,
}

/// 扫描本地版本
pub fn scan_local_versions(game_dir: String) -> Result<Vec<LocalVersionInfo>> {
    let root = PathBuf::from(&game_dir).join("versions");
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&root)?.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let Some(id) = dir.file_name().map(|n| n.to_string_lossy().into_owned()) else {
            continue;
        };
        if !dir.join(format!("{id}.json")).exists() {
            continue; // PCL2 语义：无版本 JSON 的目录不算有效版本
        }
        let (loader, loader_version, game_version) = detect_loader(&dir, &id);
        let modified_ms = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let size_bytes = dir_size(&dir);
        out.push(LocalVersionInfo {
            id,
            dir: dir.to_string_lossy().into_owned(),
            has_jar: dir.join(format!("{id}.jar")).exists(),
            loader,
            loader_version,
            game_version,
            modified_ms,
            size_bytes,
        });
    }
    out.sort_by(|a, b| b.modified_ms.cmp(&a.modified_ms));
    Ok(out)
}

/// 识别加载器类型（读版本 JSON：inheritsFrom / libraries / mainClass / id）
fn detect_loader(dir: &Path, id: &str) -> (String, String, String) {
    let json_path = dir.join(format!("{id}.json"));
    let Ok(text) = std::fs::read_to_string(&json_path) else {
        return ("vanilla".into(), String::new(), id.to_string());
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return ("vanilla".into(), String::new(), id.to_string());
    };
    let inherits = v["inheritsFrom"].as_str().unwrap_or("").to_string();
    let main_class = v["mainClass"].as_str().unwrap_or("").to_string();
    let libraries = v["libraries"].as_array().cloned().unwrap_or_default();

    let lib_str: String = libraries
        .iter()
        .filter_map(|l| l["name"].as_str())
        .collect::<Vec<_>>()
        .join("|");
    let id_str = id.to_ascii_lowercase();

    // OptiFine：libraries 含 optifine: 或 tweakClass 含 OptiFineTweaker
    if lib_str.contains("optifine:OptiFine")
        || v["arguments"]
            .pointer("/game")
            .and_then(|g| g.as_array())
            .map(|a| {
                a.iter()
                    .any(|x| x.as_str().map(|s| s.contains("OptiFine")).unwrap_or(false))
            })
            .unwrap_or(false)
        || v["minecraftArguments"].as_str().map(|s| s.contains("OptiFineTweaker")).unwrap_or(false)
    {
        return ("optifine".into(), String::new(), normalize_mc(&inherits, &id));
    }
    if lib_str.contains("net.neoforged:neoforge") || lib_str.contains("net.neoforged:forge") || id_str.contains("neoforge") {
        let ver = lib_str
            .split('|')
            .find(|s| s.contains("neoforge:neoforge") || s.contains("neoforged:forge"))
            .and_then(|s| s.split(':').nth(2))
            .unwrap_or("")
            .to_string();
        return ("neoforge".into(), ver, normalize_mc(&inherits, &id));
    }
    if lib_str.contains("minecraftforge") || id_str.contains("forge") {
        let ver = lib_str
            .split('|')
            .find(|s| s.contains("net.minecraftforge:forge"))
            .and_then(|s| s.split(':').nth(2))
            .map(|s| s.split('-').last().unwrap_or(s).to_string())
            .unwrap_or_default();
        return ("forge".into(), ver, normalize_mc(&inherits, &id));
    }
    if lib_str.contains("net.fabricmc:fabric-loader") || id_str.contains("fabric") {
        let ver = lib_str
            .split('|')
            .find(|s| s.contains("net.fabricmc:fabric-loader"))
            .and_then(|s| s.split(':').nth(2))
            .unwrap_or("")
            .to_string();
        return ("fabric".into(), ver, normalize_mc(&inherits, &id));
    }
    if lib_str.contains("org.quiltmc:quilt-loader") || id_str.contains("quilt") {
        let ver = lib_str
            .split('|')
            .find(|s| s.contains("org.quiltmc:quilt-loader"))
            .and_then(|s| s.split(':').nth(2))
            .unwrap_or("")
            .to_string();
        return ("quilt".into(), ver, normalize_mc(&inherits, &id));
    }
    if main_class.contains("launchwrapper") && inherits.is_empty() {
        // 旧版 forge（1.6-1.12）：id 常含 forge
        return ("vanilla".into(), String::new(), normalize_mc(&inherits, &id));
    }
    ("vanilla".into(), String::new(), normalize_mc(&inherits, &id))
}

fn normalize_mc(inherits: &str, id: &str) -> String {
    if !inherits.is_empty() {
        return inherits.to_string();
    }
    // 从 id 提取 1.x 形态
    let bytes = id.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'1'
            && i + 1 < bytes.len()
            && bytes[i + 1] == b'.'
        {
            let rest = &id[i..];
            let end = rest
                .find(|c: char| !(c.is_ascii_digit() || c == '.'))
                .unwrap_or(rest.len());
            let candidate = &rest[..end];
            if candidate.matches('.').count() >= 1 && !candidate.ends_with('.') {
                return candidate.to_string();
            }
        }
    }
    id.to_string()
}

fn dir_size(dir: &Path) -> i64 {
    let mut total = 0i64;
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                total += dir_size(&p);
            } else if let Ok(m) = e.metadata() {
                total += m.len() as i64;
            }
        }
    }
    total
}

// ---------------------------------------------------------------------------
// 导入 / 删除 / 重命名 / 复制
// ---------------------------------------------------------------------------

/// 导入外部版本（PCL2 式）：复制版本目录内 json/jar/bin/libs 到本游戏目录。
/// 返回新版本 id。
pub fn import_external_version(
    game_dir: String,
    source_dir: String,
    new_name: String,
) -> Result<String> {
    let src = PathBuf::from(&source_dir);
    anyhow::ensure!(src.is_dir(), "源目录不存在: {source_dir}");
    let name = if new_name.trim().is_empty() {
        src.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    } else {
        new_name.trim().to_string()
    };
    ensure_safe_name(&name)?;
    let dest = PathBuf::from(&game_dir).join("versions").join(&name);
    anyhow::ensure!(
        !dest.exists(),
        "版本 {name} 已存在"
    );
    // 校验是版本目录（含 json）
    let has_json = std::fs::read_dir(&src)?
        .flatten()
        .any(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.ends_with(".json") && n != "fmcl-settings.json"
        });
    anyhow::ensure!(has_json, "所选目录不是有效版本目录（缺少版本 JSON）");

    std::fs::create_dir_all(&dest)?;
    // 复制全部顶层文件 + 常规依赖目录
    for entry in std::fs::read_dir(&src)?.flatten() {
        let p = entry.path();
        let fname = entry.file_name().to_string_lossy().into_owned();
        if p.is_file() {
            std::fs::copy(&p, dest.join(&fname))?;
        } else if matches!(fname.as_str(), "bin" | "libs" | "natives") {
            copy_dir_all(&p, &dest.join(&fname))?;
        }
    }
    // id 归一：json 内 id 改为 new name
    let json_path = dest.join(format!("{name}.json"));
    if !json_path.exists() {
        // 找到唯一的 json 改名
        if let Some(old_json) = std::fs::read_dir(&dest)?
            .flatten()
            .map(|e| e.path())
            .find(|p| {
                p.extension().map(|e| e == "json").unwrap_or(false)
                    && p.file_name().map(|n| n != "fmcl-settings.json").unwrap_or(true)
            })
        {
            std::fs::rename(&old_json, &json_path)?;
        }
    }
    if json_path.exists() {
        let text = std::fs::read_to_string(&json_path)?;
        if let Ok(mut v) = serde_json::from_str::<Value>(&text) {
            v["id"] = serde_json::json!(name);
            std::fs::write(&json_path, serde_json::to_vec_pretty(&v)?)?;
        }
    }
    crate::log_info!("Versions", "导入外部版本 {name} ← {}", src.display());
    Ok(name)
}

/// 删除版本（可选删除隔离目录内的存档等；默认整目录删除）
pub fn delete_version(game_dir: String, version_id: String) -> Result<()> {
    let dir = PathBuf::from(&game_dir).join("versions").join(&version_id);
    anyhow::ensure!(dir.is_dir(), "版本目录不存在: {version_id}");
    std::fs::remove_dir_all(&dir).context("删除版本目录失败")?;
    crate::log_info!("Versions", "已删除版本 {version_id}");
    Ok(())
}

/// 重命名版本（含 JSON 内 id 同步）
pub fn rename_version(game_dir: String, version_id: String, new_name: String) -> Result<()> {
    ensure_safe_name(&new_name)?;
    let old_dir = PathBuf::from(&game_dir).join("versions").join(&version_id);
    let new_dir = PathBuf::from(&game_dir).join("versions").join(&new_name);
    anyhow::ensure!(old_dir.is_dir(), "版本不存在: {version_id}");
    anyhow::ensure!(!new_dir.exists(), "目标名称已存在: {new_name}");
    std::fs::rename(&old_dir, &new_dir)?;
    let old_json = new_dir.join(format!("{version_id}.json"));
    let new_json = new_dir.join(format!("{new_name}.json"));
    if old_json.exists() {
        std::fs::rename(&old_json, &new_json)?;
        let text = std::fs::read_to_string(&new_json)?;
        if let Ok(mut v) = serde_json::from_str::<Value>(&text) {
            v["id"] = serde_json::json!(new_name);
            std::fs::write(&new_json, serde_json::to_vec_pretty(&v)?)?;
        }
    }
    let old_jar = new_dir.join(format!("{version_id}.jar"));
    if old_jar.exists() {
        std::fs::rename(&old_jar, new_dir.join(format!("{new_name}.jar")))?;
    }
    crate::log_info!("Versions", "重命名版本 {version_id} → {new_name}");
    Ok(())
}

/// 复制版本
pub fn copy_version(game_dir: String, version_id: String, new_name: String) -> Result<()> {
    ensure_safe_name(&new_name)?;
    let src = PathBuf::from(&game_dir).join("versions").join(&version_id);
    let dest = PathBuf::from(&game_dir).join("versions").join(&new_name);
    anyhow::ensure!(src.is_dir(), "版本不存在: {version_id}");
    anyhow::ensure!(!dest.exists(), "目标名称已存在: {new_name}");
    copy_dir_all(&src, &dest)?;
    let json_path = dest.join(format!("{new_name}.json"));
    let old_json = dest.join(format!("{version_id}.json"));
    if old_json.exists() {
        std::fs::rename(&old_json, &json_path)?;
        let text = std::fs::read_to_string(&json_path)?;
        if let Ok(mut v) = serde_json::from_str::<Value>(&text) {
            v["id"] = serde_json::json!(new_name);
            std::fs::write(&json_path, serde_json::to_vec_pretty(&v)?)?;
        }
    }
    Ok(())
}

fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)?.flatten() {
        let ty = entry.file_type()?;
        let target = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

fn ensure_safe_name(name: &str) -> Result<()> {
    let bad = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    if name.is_empty() {
        bail!("名称不能为空");
    }
    if name.chars().any(|c| bad.contains(&c)) || name == "." || name == ".." {
        bail!("名称包含非法字符");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 补全（PCL2 式「补全文件」）
// ---------------------------------------------------------------------------

/// 补全版本全部文件（客户端 jar / 支持库 / 资源 / 日志配置），流式进度。
#[allow(clippy::too_many_arguments)]
pub async fn complete_version(
    game_dir: String,
    version_id: String,
    bmclapi_first: bool,
    concurrency: i32,
    session_id: String,
    sink: Sink,
) -> Result<()> {
    if !crate::util::cancel::CANCEL_REGISTRY.contains(&session_id) {
        crate::util::cancel::CANCEL_REGISTRY.create(&session_id);
    }
    let cancelled: CancelFlag = crate::util::cancel::CANCEL_REGISTRY.handle(&session_id);
    let emit = |ev: InstallProgressEvent| {
        let _ = sink.add(ev);
    };
    let pg = Progress::new(&emit, cancelled.clone());
    let client = crate::util::http::build_public_client()?;
    let game = PathBuf::from(&game_dir);
    let version_dir = game.join("versions").join(&version_id);
    let json_path = version_dir.join(format!("{version_id}.json"));
    anyhow::ensure!(json_path.exists(), "版本 {version_id} 不存在");

    let result = run_completion(
        &client, &game, &version_id, &pg, &sink, bmclapi_first, concurrency.max(1) as usize, &cancelled,
    )
    .await;
    match result {
        Ok(()) => {
            pg.step("done", "补全完成", 1.0);
            crate::util::cancel::CANCEL_REGISTRY.dispose(&session_id);
            Ok(())
        }
        Err(e) => {
            if !e.to_string().contains("已取消") {
                let _ = sink.add(InstallProgressEvent {
                    phase: "failed".into(),
                    message: format!("补全失败: {e}"),
                    progress: 0.0,
                });
            }
            Err(e)
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_completion(
    client: &reqwest::Client,
    game: &Path,
    version_id: &str,
    pg: &Progress<'_>,
    sink: &Sink,
    bmclapi_first: bool,
    concurrency: usize,
    cancelled: &CancelFlag,
) -> Result<()> {
    let emit = |ev: InstallProgressEvent| {
        let _ = sink.add(ev);
    };
    // 解析版本链
    let leaf = read_version_json(game, version_id)?;
    let chain = resolve_chain(&leaf, game);
    let merged = merge_chain(&chain);
    crate::log_info!(
        "Completion",
        "补全 {}（链: {}）",
        version_id,
        chain.iter().map(|c| c.id.clone()).collect::<Vec<_>>().join(" ← ")
    );

    // 1. 客户端 jar（原版根）
    pg.step("download", "校验客户端...", 0.02);
    if let Some(vanilla_id) = chain.iter().find(|c| c.vanilla_download.is_some()).map(|c| c.id.clone()) {
        let info = merged
            .vanilla_download
            .clone()
            .ok_or_else(|| anyhow!("版本缺少客户端下载定义"))?;
        let jar_path = game.join("versions").join(&vanilla_id).join(format!("{vanilla_id}.jar"));
        if !jar_path.exists() {
            let urls = client_urls_for(&info, bmclapi_first);
            download_with_fallback(
                &urls,
                &jar_path,
                info["sha1"].as_str(),
                info["size"].as_i64(),
            )
            .await
            .context("客户端下载失败")?;
        }
    }

    // 2. 支持库
    pg.step("download", "扫描支持库...", 0.10);
    let lib_items = collect_lib_items(Some(&merged.libraries_value), game, bmclapi_first);
    let missing_libs: Vec<_> = lib_items.iter().filter(|it| !verify_existing(it)).collect();
    crate::log_info!("Completion", "待下载支持库 {} 个", missing_libs.len());
    let items: Vec<_> = missing_libs.into_iter().cloned().collect();
    run_batch(&emit, cancelled, &items, 0.10, 0.35, concurrency, "支持库").await?;

    // 3. 资源（assetIndex 来自继承链合并结果）
    pg.step("download", "扫描资源文件...", 0.35);
    let mut asset_lookup = serde_json::Map::new();
    if let Some(ai) = &merged.asset_index {
        asset_lookup.insert("assetIndex".into(), ai.clone());
    }
    let asset_items = collect_asset_items(client, &Value::Object(asset_lookup), game, bmclapi_first)
        .await
        .unwrap_or_default();
    run_batch(&emit, cancelled, &asset_items, 0.35, 0.85, concurrency, "资源文件").await?;

    // 4. 日志配置
    if let Some(log_cfg) = merged.raw.pointer("/logging/client/file") {
        let url = log_cfg["url"].as_str().unwrap_or_default();
        if !url.is_empty() {
            let name = log_cfg["path"]
                .as_str()
                .and_then(|p| p.split('/').last())
                .unwrap_or("client-1.12.xml");
            let save = game.join("assets").join("log_configs").join(name);
            if !save.exists() {
                let urls = crate::api::install::dual_urls(url, bmclapi_first);
                download_with_fallback(
                    &urls,
                    &save,
                    log_cfg["sha1"].as_str(),
                    log_cfg["size"].as_i64(),
                )
                .await
                .ok();
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 版本链解析（与 launch 共用逻辑放在 install.rs 之上独立实现）
// ---------------------------------------------------------------------------

/// 链上单个版本节点（crate 内部使用，不经 FRB 暴露）
pub(crate) struct ChainNode {
    pub(crate) id: String,
    pub(crate) raw: Value,
    /// 仅原版根节点带 /downloads/client
    pub(crate) vanilla_download: Option<Value>,
}

fn read_version_json(game: &Path, id: &str) -> Result<Value> {
    let path = game.join("versions").join(id).join(format!("{id}.json"));
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("读取版本 JSON 失败: {}", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("解析版本 JSON 失败: {id}"))
}

/// 自底向上解析 inheritsFrom 链（防环，深度上限 16）
pub(crate) fn resolve_chain(leaf: &Value, game: &Path) -> Vec<ChainNode> {
    let mut chain: Vec<ChainNode> = Vec::new();
    let mut current = leaf.clone();
    let mut seen = std::collections::HashSet::new();
    let mut depth = 0;
    loop {
        depth += 1;
        if depth > 16 {
            break;
        }
        let id = current["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() || !seen.insert(id.clone()) {
            break;
        }
        let vanilla_download = current
            .pointer("/downloads/client")
            .cloned()
            .filter(|_| current["assetIndex"].is_object());
        let inherits = current["inheritsFrom"].as_str().map(|s| s.to_string());
        chain.push(ChainNode {
            id,
            vanilla_download,
            raw: current.clone(),
        });
        match inherits {
            Some(parent) => match read_version_json(game, &parent) {
                Ok(p) => current = p,
                Err(_) => break,
            },
            None => break,
        }
    }
    chain
}

/// 链合并结果（原版根 → 叶子覆盖）
pub(crate) struct MergedVersion {
    pub(crate) id: String,
    pub(crate) main_class: String,
    pub(crate) libraries_value: Value,
    /// 合并后的 arguments（jvm + game 数组元素含规则对象）
    pub(crate) jvm_arguments: Vec<Value>,
    pub(crate) game_arguments: Vec<Value>,
    pub(crate) minecraft_arguments: Option<String>,
    pub(crate) asset_index: Option<Value>,
    pub(crate) assets_id: Option<String>,
    pub(crate) java_major: Option<i32>,
    pub(crate) logging_client: Option<Value>,
    pub(crate) vanilla_download: Option<Value>,
    pub(crate) raw: Value,
}

/// 合并继承链（父在前叶子在后）
pub(crate) fn merge_chain(chain: &[ChainNode]) -> MergedVersion {
    let mut libs: Vec<Value> = Vec::new();
    let mut jvm_args: Vec<Value> = Vec::new();
    let mut game_args: Vec<Value> = Vec::new();
    let mut main_class = String::new();
    let mut minecraft_arguments: Option<String> = None;
    let mut asset_index: Option<Value> = None;
    let mut assets_id: Option<String> = None;
    let mut java_major: Option<i32> = None;
    let mut logging_client: Option<Value> = None;
    let mut vanilla_download: Option<Value> = None;

    for node in chain {
        if let Some(arr) = node.raw["libraries"].as_array() {
            libs.extend(arr.iter().cloned());
        }
        if let Some(args) = node.raw["arguments"].as_object() {
            if let Some(j) = args.get("jvm").and_then(|v| v.as_array()) {
                jvm_args.extend(j.iter().cloned());
            }
            if let Some(g) = args.get("game").and_then(|v| v.as_array()) {
                game_args.extend(g.iter().cloned());
            }
        }
        if !node.raw["mainClass"].as_str().unwrap_or("").is_empty() {
            main_class = node.raw["mainClass"].as_str().unwrap_or("").to_string();
        }
        if let Some(s) = node.raw["minecraftArguments"].as_str() {
            minecraft_arguments = Some(s.to_string());
        }
        if node.raw["assetIndex"].is_object() {
            asset_index = Some(node.raw["assetIndex"].clone());
        }
        if let Some(a) = node.raw["assets"].as_str() {
            assets_id = Some(a.to_string());
        }
        if let Some(m) = node.raw["javaVersion"].pointer("/majorVersion").and_then(|v| v.as_i64()) {
            java_major = Some(m as i32);
        }
        if node.raw["logging"].is_object() {
            logging_client = Some(node.raw["logging"]["client"].clone());
        }
        if node.raw["downloads"].is_object() && node.raw["downloads"]["client"].is_object() {
            vanilla_download = Some(node.raw["downloads"]["client"].clone());
        }
    }

    let id = chain.last().map(|c| c.id.clone()).unwrap_or_default();
    let raw = chain.last().map(|c| c.raw.clone()).unwrap_or(Value::Null);
    MergedVersion {
        id,
        main_class,
        libraries_value: Value::Array(libs),
        jvm_arguments: jvm_args,
        game_arguments: game_args,
        minecraft_arguments,
        asset_index,
        assets_id,
        java_major,
        logging_client,
        vanilla_download,
        raw,
    }
}

/// 供 UI 展示的 BMCLAPI 根（测试/调试）
pub fn bmclapi_root() -> String {
    BMCLAPI_ROOT.to_string()
}
