//! 资源下载 API（对齐 PCL2 下载页：模组 / 资源包 / 光影 / 数据包 / 整合包）。
//!
//! - 在线搜索与文件下载：Modrinth API（无需密钥）
//! - 整合包安装：Modrinth `.mrpack`（modrinth.index.json）与
//!   CurseForge `manifest.json`（直链 forgecdn 计算）双支持

use crate::core::settings;
use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(12))
        .read_timeout(std::time::Duration::from_secs(45))
        .timeout(std::time::Duration::from_secs(300))
        .user_agent("FMCL/0.1.0 (github.com/Ming-QWQ520/FMCL)")
        .build()?)
}

// ---------------------------------------------------------------------------
// Modrinth 搜索与下载
// ---------------------------------------------------------------------------

/// 搜索结果条目
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub project_id: String,
    pub slug: String,
    pub title: String,
    pub description: String,
    pub author: String,
    pub downloads: i64,
    pub icon_url: String,
    /// mod / resourcepack / shaderpack / datapack / modpack
    pub category: String,
    pub date_modified: String,
}

/// 搜索 Modrinth 内容（按当前游戏版本与加载器过滤）
pub async fn search_content(
    query: String,
    category: String,
    mc_version: String,
    loader: String,
    index: i32,
) -> Result<Vec<SearchHit>> {
    let facets = build_facets(&category, &mc_version, &loader);
    let url = format!(
        "https://api.modrinth.com/v2/search?limit=20&index=relevance&offset={}&query={}&facets={}",
        index.max(0) * 20,
        urlencoding_lite(&query),
        urlencoding_lite(&facets),
    );
    let c = client()?;
    let json: Value = c
        .get(&url)
        .send()
        .await
        .map_err(|e| anyhow!("搜索失败: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("搜索结果解析失败: {e}"))?;
    let hits = json["hits"]
        .as_array()
        .ok_or_else(|| anyhow!("搜索结果格式异常"))?;
    Ok(hits
        .iter()
        .map(|h| SearchHit {
            project_id: h["project_id"].as_str().unwrap_or("").to_string(),
            slug: h["slug"].as_str().unwrap_or("").to_string(),
            title: h["title"].as_str().unwrap_or("").to_string(),
            description: h["description"].as_str().unwrap_or("").to_string(),
            author: h["author"].as_str().unwrap_or("").to_string(),
            downloads: h["downloads"].as_i64().unwrap_or(0),
            icon_url: h["icon_url"].as_str().unwrap_or("").to_string(),
            category: category.clone(),
            date_modified: h["date_modified"].as_str().unwrap_or("").to_string(),
        })
        .collect())
}

fn build_facets(category: &str, mc_version: &str, loader: &str) -> String {
    let mut parts: Vec<String> = Vec::new();
    let cat = match category {
        "mod" => "mod",
        "resourcepack" => "resourcepack",
        "shaderpack" => "shaderpack",
        "datapack" => "datapack",
        "modpack" => "modpack",
        _ => "mod",
    };
    parts.push(format!("[\"project_type:{}\"]", cat));
    if !mc_version.is_empty() {
        parts.push(format!("[\"versions:{}\"]", mc_version));
    }
    let loader_lc = loader.to_ascii_lowercase();
    if matches!(cat, "mod" | "datapack")
        && matches!(loader_lc.as_str(), "fabric" | "forge" | "quilt" | "neoforge")
    {
        parts.push(format!("[\"categories:{}\"]", loader_lc));
    }
    format!("[{}]", parts.join(","))
}

/// 极简 URL 编码（保守集合）
fn urlencoding_lite(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 项目可下载文件版本
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentFile {
    pub version_id: String,
    pub name: String,
    pub version_number: String,
    pub date_published: String,
    pub size_bytes: i64,
    pub download_url: String,
    pub filename: String,
    pub game_versions: Vec<String>,
    pub loaders: Vec<String>,
    pub version_type: String,
}

/// 列出项目文件版本（时间倒序）
pub async fn list_project_files(project_id: String) -> Result<Vec<ContentFile>> {
    let c = client()?;
    let json: Value = c
        .get(format!("https://api.modrinth.com/v2/project/{project_id}/version"))
        .send()
        .await
        .map_err(|e| anyhow!("获取版本列表失败: {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("版本列表解析失败: {e}"))?;
    let arr = json.as_array().ok_or_else(|| anyhow!("版本列表格式异常"))?;
    Ok(arr
        .iter()
        .map(|v| {
            let files = v["files"].as_array().cloned().unwrap_or_default();
            let primary = files
                .iter()
                .find(|f| f["primary"].as_bool().unwrap_or(false))
                .or_else(|| files.first())
                .cloned()
                .unwrap_or(Value::Null);
            ContentFile {
                version_id: v["id"].as_str().unwrap_or("").to_string(),
                name: v["name"].as_str().unwrap_or("").to_string(),
                version_number: v["version_number"].as_str().unwrap_or("").to_string(),
                date_published: v["date_published"].as_str().unwrap_or("").to_string(),
                size_bytes: primary["size"].as_i64().unwrap_or(0),
                download_url: primary["url"].as_str().unwrap_or("").to_string(),
                filename: primary["filename"].as_str().unwrap_or("").to_string(),
                game_versions: v["game_versions"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                    .unwrap_or_default(),
                loaders: v["loaders"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                    .unwrap_or_default(),
                version_type: v["version_type"].as_str().unwrap_or("release").to_string(),
            }
        })
        .collect())
}

/// 安装内容文件到对应目录（随版本隔离落点）。
/// 返回保存路径。
pub async fn install_content_file(
    game_dir: String,
    version_id: String,
    category: String,
    download_url: String,
    filename: String,
    session_id: String,
) -> Result<String> {
    let global = settings::load_settings();
    let sub = match category.as_str() {
        "mod" => "mods",
        "resourcepack" => "resourcepacks",
        "shaderpack" => "shaderpacks",
        "datapack" => "datapacks",
        "modpack" => bail!("整合包请使用 install_modpack"),
        _ => "mods",
    };
    let dir = settings::versioned_subdir(&global, std::path::Path::new(&game_dir), &version_id, sub);
    std::fs::create_dir_all(&dir)?;
    let save = dir.join(&filename);
    anyhow::ensure!(!download_url.is_empty(), "下载地址为空");

    if !crate::util::cancel::CANCEL_REGISTRY.contains(&session_id) {
        crate::util::cancel::CANCEL_REGISTRY.create(&session_id);
    }
    let cancelled = crate::util::cancel::CANCEL_REGISTRY.handle(&session_id);
    let item = crate::api::download::DownloadItem {
        url: download_url.clone(),
        save_path: save.to_string_lossy().into_owned(),
        expected_sha1: None,
        expected_size: None,
        alt_urls: Vec::new(),
    };
    let (ok, _) = crate::util::http::download_all(
        std::slice::from_ref(&item),
        1,
        cancelled,
        None,
        |_, _, _| {},
    )
    .await;
    crate::util::cancel::CANCEL_REGISTRY.dispose(&session_id);
    anyhow::ensure!(ok == 1, "下载失败: {download_url}");
    crate::log_info!("Content", "已安装 {category}: {}", save.display());
    Ok(save.to_string_lossy().into_owned())
}

/// 删除已安装内容文件
pub fn delete_content_file(path: String) -> Result<()> {
    let p = std::path::Path::new(&path);
    anyhow::ensure!(p.exists(), "文件不存在: {path}");
    // 安全限制：只允许删除 mods/resourcepacks/shaderpacks/datapacks 下文件
    let allowed = ["mods", "resourcepacks", "shaderpacks", "datapacks"];
    anyhow::ensure!(
        p.parent()
            .and_then(|d| d.file_name())
            .map(|n| allowed.contains(&n.to_string_lossy().as_ref()))
            .unwrap_or(false),
        "仅允许删除内容目录下的文件"
    );
    std::fs::remove_file(p)?;
    Ok(())
}

/// 列出版本已安装的内容文件（随隔离落点）
pub fn list_installed_contents(
    game_dir: String,
    version_id: String,
    category: String,
) -> Result<Vec<InstalledContent>> {
    let global = settings::load_settings();
    let sub = match category.as_str() {
        "mod" => "mods",
        "resourcepack" => "resourcepacks",
        "shaderpack" => "shaderpacks",
        "datapack" => "datapacks",
        _ => "mods",
    };
    let dir = settings::versioned_subdir(&global, std::path::Path::new(&game_dir), &version_id, sub);
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        for e in rd.flatten() {
            let p = e.path();
            if !p.is_file() {
                continue;
            }
            let meta = e.metadata().ok();
            out.push(InstalledContent {
                name: p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                path: p.to_string_lossy().into_owned(),
                size_bytes: meta.as_ref().map(|m| m.len() as i64).unwrap_or(0),
                modified_ms: meta
                    .as_ref()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0),
            });
        }
    }
    out.sort_by_key(|c| std::cmp::Reverse(c.modified_ms));
    Ok(out)
}

/// 已安装内容条目
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledContent {
    pub name: String,
    pub path: String,
    pub size_bytes: i64,
    pub modified_ms: i64,
}

// ---------------------------------------------------------------------------
// 整合包
// ---------------------------------------------------------------------------

/// 整合包清单（两类格式归一）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackManifest {
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub mc_version: String,
    /// vanilla / forge / fabric / quilt / neoforge
    pub loader: String,
    pub loader_version: String,
    /// kind: "modrinth" | "curseforge"
    pub kind: String,
    pub file_count: usize,
}

struct ModpackFile {
    path: String,
    url: String,
    sha1: Option<String>,
    size: Option<i64>,
}

/// 解析整合包（.mrpack / CurseForge zip）
pub async fn parse_modpack(zip_path: String) -> Result<ModpackManifest> {
    let path = std::path::Path::new(&zip_path);
    anyhow::ensure!(path.exists(), "整合包文件不存在: {zip_path}");
    let read_entry = |name: &str| -> Result<String> {
        let bytes = crate::api::archive::read_zip_entry(zip_path.clone(), name.to_string())
            .map_err(|_| anyhow!("缺少 {name}（不是有效的整合包）"))?;
        String::from_utf8(bytes).map_err(|_| anyhow!("{name} 编码异常"))
    };

    // Modrinth .mrpack
    if let Ok(index_text) = read_entry("modrinth.index.json") {
        let index: Value = serde_json::from_str(&index_text).context("modrinth.index.json 解析失败")?;
        let mc = index["dependencies"]["minecraft"]
            .as_str()
            .unwrap_or("")
            .to_string();
        let (loader, loader_ver) = loader_from_deps(&index["dependencies"]);
        return Ok(ModpackManifest {
            name: index["name"].as_str().unwrap_or("未命名整合包").to_string(),
            version: index["versionId"].as_str().unwrap_or("").to_string(),
            author: index["author"].as_str().unwrap_or("").to_string(),
            description: index["summary"].as_str().unwrap_or("").to_string(),
            mc_version: mc,
            loader,
            loader_version: loader_ver,
            kind: "modrinth".into(),
            file_count: index["files"].as_array().map(|a| a.len()).unwrap_or(0),
        });
    }

    // CurseForge
    if let Ok(manifest_text) = read_entry("manifest.json") {
        let m: Value = serde_json::from_str(&manifest_text).context("manifest.json 解析失败")?;
        let (loader, loader_ver) = {
            let ml = m["minecraft"]["modLoaders"].as_array().and_then(|a| a.first());
            match ml {
                Some(l) => {
                    let id = l["id"].as_str().unwrap_or("");
                    let kind = l["primary"].as_bool().unwrap_or(true);
                    if kind {
                        if let Some((k, v)) = id.split_once('-') {
                            (normalize_loader(k), v.to_string())
                        } else {
                            (normalize_loader(id), String::new())
                        }
                    } else {
                        ("vanilla".into(), String::new())
                    }
                }
                None => ("vanilla".into(), String::new()),
            }
        };
        let mc = m["minecraft"]["version"].as_str().unwrap_or("").to_string();
        return Ok(ModpackManifest {
            name: m["name"].as_str().unwrap_or("未命名整合包").to_string(),
            version: m["version"].as_str().unwrap_or("").to_string(),
            author: m["author"].as_str().unwrap_or("").to_string(),
            description: String::new(),
            mc_version: mc,
            loader,
            loader_version: loader_ver,
            kind: "curseforge".into(),
            file_count: m["files"].as_array().map(|a| a.len()).unwrap_or(0),
        });
    }

    bail!("无法识别的整合包格式（缺少 modrinth.index.json / manifest.json）")
}

fn loader_from_deps(deps: &Value) -> (String, String) {
    let map = deps.as_object();
    if let Some(m) = map {
        for (k, v) in m {
            let ks = k.to_ascii_lowercase();
            if ks.contains("fabric") {
                return ("fabric".into(), v.as_str().unwrap_or("").to_string());
            }
            if ks.contains("quilt") {
                return ("quilt".into(), v.as_str().unwrap_or("").to_string());
            }
            if ks.contains("neoforge") {
                return ("neoforge".into(), v.as_str().unwrap_or("").to_string());
            }
            if ks.contains("forge") {
                return ("forge".into(), v.as_str().unwrap_or("").to_string());
            }
        }
    }
    ("vanilla".into(), String::new())
}

fn normalize_loader(k: &str) -> String {
    match k.to_ascii_lowercase().as_str() {
        "fabric" => "fabric".into(),
        "quilt" => "quilt".into(),
        "neoforge" => "neoforge".into(),
        "forge" => "forge".into(),
        _ => "vanilla".into(),
    }
}

/// 整合包安装进度事件
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModpackProgressEvent {
    /// extract | download | install | done | failed
    pub phase: String,
    pub message: String,
    pub progress: f64,
}

/// 安装整合包为独立版本（PCL2 式）。
/// 返回新版本名。
#[allow(clippy::too_many_arguments)]
pub async fn install_modpack(
    zip_path: String,
    game_dir: String,
    instance_name: String,
    java_path: String,
    use_bmclapi: bool,
    concurrency: i32,
    session_id: String,
    em: &crate::bridge::Emitter,
) -> Result<String> {
    let emit = |phase: &str, msg: &str, p: f64| {
        em.send(&ModpackProgressEvent {
            phase: phase.into(),
            message: msg.into(),
            progress: p.clamp(0.0, 1.0),
        });
    };
    if !crate::util::cancel::CANCEL_REGISTRY.contains(&session_id) {
        crate::util::cancel::CANCEL_REGISTRY.create(&session_id);
    }
    let cancelled = crate::util::cancel::CANCEL_REGISTRY.handle(&session_id);
    let check_cancel = || -> Result<()> {
        if cancelled.load(std::sync::atomic::Ordering::Relaxed) {
            bail!("已取消");
        }
        Ok(())
    };

    let manifest = parse_modpack(zip_path.clone()).await?;
    let name = if instance_name.trim().is_empty() {
        manifest.name.clone()
    } else {
        instance_name.trim().to_string()
    };
    let name = dedupe_name(&game_dir, &name);
    let version_dir = std::path::Path::new(&game_dir).join("versions").join(&name);
    std::fs::create_dir_all(&version_dir)?;
    emit("extract", &format!("解析整合包：{name}"), 0.02);

    let result: Result<String> = async {
        // ---------- 收集文件清单 ----------
        let mut files: Vec<ModpackFile> = Vec::new();
        match manifest.kind.as_str() {
            "modrinth" => {
                let bytes =
                    crate::api::archive::read_zip_entry(zip_path.clone(), "modrinth.index.json".into())?;
                let index: Value = serde_json::from_slice(&bytes)?;
                for f in index["files"].as_array().cloned().unwrap_or_default() {
                    let path = f["path"].as_str().unwrap_or("").to_string();
                    let dl = f["downloads"]
                        .as_array()
                        .and_then(|a| a.first())
                        .and_then(|u| u.as_str())
                        .unwrap_or("")
                        .to_string();
                    if path.is_empty() || dl.is_empty() {
                        continue;
                    }
                    files.push(ModpackFile {
                        path,
                        url: dl,
                        sha1: f["hashes"]["sha1"].as_str().map(String::from),
                        size: f["fileSize"].as_i64(),
                    });
                }
            }
            "curseforge" => {
                let bytes = crate::api::archive::read_zip_entry(zip_path.clone(), "manifest.json".into())?;
                let m: Value = serde_json::from_slice(&bytes)?;
                for f in m["files"].as_array().cloned().unwrap_or_default() {
                    let project_id = f["projectID"].as_i64().unwrap_or(0);
                    let file_id = f["fileID"].as_i64().unwrap_or(0);
                    if project_id == 0 || file_id == 0 {
                        continue;
                    }
                    // 文件名需通过 CF API 获取；无密钥环境下使用
                    // community 镜像 api.cfwidget.com 查询项目文件名。
                    let file_name = fetch_cf_file_name(project_id, file_id).await;
                    let Some(file_name) = file_name else {
                        crate::log_warn!(
                            "Modpack",
                            "无法解析 CurseForge 文件 {project_id}/{file_id}，已跳过"
                        );
                        continue;
                    };
                    let a = (file_id / 1000).to_string();
                    let b = format!("{:03}", file_id % 1000);
                    let url = format!(
                        "https://mediafilez.forgecdn.net/files/{a}/{b}/{file_name}"
                    );
                    // 路径：CF 模组默认进 mods
                    files.push(ModpackFile {
                        path: format!("mods/{file_name}"),
                        url,
                        sha1: None,
                        size: None,
                    });
                }
            }
            _ => bail!("未知整合包类型"),
        }

        // ---------- 覆盖文件解压（overrides / overrides 目录） ----------
        // Modrinth 与 CurseForge 均使用 overrides/ 目录承载覆盖文件
        let override_prefix = "overrides/".to_string();
        extract_zip_overrides(&zip_path, &override_prefix, &game_dir, &name, &emit)?;
        emit("extract", "覆盖文件就绪", 0.15);

        // ---------- 下载文件 ----------
        let items: Vec<crate::api::download::DownloadItem> = files
            .iter()
            .map(|f| crate::api::download::DownloadItem {
                url: f.url.clone(),
                save_path: std::path::Path::new(&game_dir)
                    .join("versions")
                    .join(&name)
                    .join(&f.path)
                    .to_string_lossy()
                    .into_owned(),
                expected_sha1: f.sha1.clone(),
                expected_size: f.size,
                alt_urls: Vec::new(),
            })
            .collect();
        let total = items.len() as i32;
        emit("download", &format!("下载整合包文件（{total} 个）..."), 0.2);
        let counter = std::sync::Arc::new(std::sync::Mutex::new((0i32, std::time::Instant::now())));
        let sink_c = em.clone();
        let counter_c = counter.clone();
        let (ok, failed) = crate::util::http::download_all(
            &items,
            concurrency.max(1) as usize,
            cancelled.clone(),
            None,
            move |_s, _i, _e| {
                let mut g = counter_c.lock().unwrap();
                g.0 += 1;
                let now = std::time::Instant::now();
                if now.duration_since(g.1).as_millis() >= 150 || g.0 >= total {
                    g.1 = now;
                    sink_c.send(&ModpackProgressEvent {
                        phase: "download".into(),
                        message: format!("下载整合包文件（{}/{}）", g.0, total),
                        progress: 0.2 + 0.55 * (g.0 as f64 / total.max(1) as f64),
                    });
                }
            },
        )
        .await;
        check_cancel()?;
        if failed > 0 {
            bail!("整合包文件下载失败（{failed}/{total}）");
        }
        let _ = ok;

        // ---------- 安装游戏与加载器 ----------
        emit("install", "安装游戏本体与加载器...", 0.8);
        let install_sink = em.clone();
        let request = crate::api::install::InstallRequest {
            game_dir: game_dir.clone(),
            instance_name: name.clone(),
            game_version: manifest.mc_version.clone(),
            version_json_url: None,
            fabric_version: if manifest.loader == "fabric" {
                Some(manifest.loader_version.clone())
            } else {
                None
            },
            quilt_version: if manifest.loader == "quilt" {
                Some(manifest.loader_version.clone())
            } else {
                None
            },
            forge_version: if manifest.loader == "forge" {
                Some(manifest.loader_version.clone())
            } else {
                None
            },
            neoforge_version: if manifest.loader == "neoforge" {
                Some(manifest.loader_version.clone())
            } else {
                None
            },
            optifine: None,
            java_path,
            use_bmclapi,
            concurrency,
            session_id: format!("{session_id}-modpack-install"),
        };
        // 复用合并安装管线（InstallProgressEvent → ModpackProgressEvent 桥接）
        let (tx, mut rx) =
            tokio::sync::mpsc::unbounded_channel::<crate::api::install::InstallProgressEvent>();
        let fwd = tokio::spawn(async move {
            while let Some(ev) = rx.recv().await {
                install_sink.send(&ModpackProgressEvent {
                    phase: "install".into(),
                    message: ev.message,
                    progress: 0.8 + 0.18 * ev.progress,
                });
            }
        });
        // 使用内部核心函数 install_combined_core（进度走回调；
        // 调用返回时回调与其持有的 tx 一并释放，fwd 随之结束）
        let install_result = crate::api::install::install_combined_core(
            request,
            move |ev: crate::api::install::InstallProgressEvent| {
                let _ = tx.send(ev);
            },
        )
        .await;
        let _ = fwd.await;
        install_result?;

        emit("done", &format!("整合包安装完成：{name}"), 1.0);
        Ok(name)
    }
    .await;

    match result {
        Ok(n) => {
            crate::util::cancel::CANCEL_REGISTRY.dispose(&session_id);
            crate::log_info!("Modpack", "整合包安装完成: {n}");
            Ok(n)
        }
        Err(e) => {
            crate::util::cancel::CANCEL_REGISTRY.dispose(&session_id);
            em.send(&ModpackProgressEvent {
                phase: "failed".into(),
                message: format!("整合包安装失败: {e}"),
                progress: 0.0,
            });
            Err(e)
        }
    }
}

/// 版本名去重（name / name-2 / name-3 ...）
fn dedupe_name(game_dir: &str, base: &str) -> String {
    let mut name = base.to_string();
    let mut i = 2;
    while std::path::Path::new(game_dir)
        .join("versions")
        .join(&name)
        .exists()
    {
        name = format!("{base}-{i}");
        i += 1;
    }
    name
}

/// 解压整合包 overrides 到版本目录
fn extract_zip_overrides(
    zip_path: &str,
    prefix: &str,
    game_dir: &str,
    name: &str,
    emit: &dyn Fn(&str, &str, f64),
) -> Result<()> {
    let file = std::fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    let base = std::path::Path::new(game_dir).join("versions").join(name);
    let mut count = 0;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let ename = entry.name().to_string();
        if !ename.starts_with(prefix) || entry.is_dir() {
            continue;
        }
        let rel = &ename[prefix.len()..];
        if rel.is_empty() {
            continue;
        }
        let out = crate::api::archive::safe_join(&base, rel)?;
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::io::copy(&mut entry, &mut std::fs::File::create(&out)?)?;
        count += 1;
        if count % 200 == 0 {
            emit("extract", &format!("解压覆盖文件（{count}）..."), 0.12);
        }
    }
    crate::log_info!("Modpack", "覆盖文件解压 {count} 个");
    Ok(())
}

/// 通过 cfwidget 社区 API 获取 CurseForge 文件名（无需 API key）
async fn fetch_cf_file_name(project_id: i64, file_id: i64) -> Option<String> {
    let c = client().ok()?;
    let json: Value = c
        .get(format!("https://api.cfwidget.com/{project_id}"))
        .header("Accept", "application/json")
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    // 项目文件列表中按 id 匹配
    let files = json["files"].as_array()?;
    files
        .iter()
        .find(|f| f["id"].as_i64() == Some(file_id))
        .and_then(|f| f["name"].as_str())
        .map(String::from)
}
