//! 启动游戏 API —— 完整启动管线（Rust 全量实现，对齐 PCL2 启动流程）。
//!
//! ```
//! 账户 → 解析版本链 → 合并 → 补全文件(客户端/库/资源) → 解压 natives
//! → 选择 Java(含自动安装) → 内存安全校验 → 外置登录准备(authlib-injector)
//! → 构建参数(JVM+游戏) → 启动前命令 → spawn → 日志流(双路落盘) → 退出分析
//! ```
//!
//! Flutter 仅通过事件流观察进度/日志/退出码。

use crate::api::install::{
    client_urls_for, collect_asset_items, collect_lib_items, download_with_fallback, lib_allowed,
    coord_to_path_pub, verify_existing,
};
use crate::api::versions_api::{merge_chain, resolve_chain, ChainNode, MergedVersion};
use crate::bridge::Emitter;
use crate::core::settings;
use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;

type CancelFlag = Arc<std::sync::atomic::AtomicBool>;

/// 启动用账户信息（Flutter 从账户系统取当前账户传入）
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LaunchAccount {
    /// offline | microsoft | yggdrasil
    pub account_type: String,
    pub name: String,
    pub uuid: String,
    pub access_token: String,
    /// Yggdrasil 认证服务器 API 根
    pub yggdrasil_server: String,
}

/// 启动请求（全部决策在 Rust，Flutter 只传展示层拿到的值）
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LaunchOptions {
    pub game_dir: String,
    pub version_id: String,
    pub account: Option<LaunchAccount>,

    /// 手动 Java 覆盖（调用级 > 全局 > 自动）
    pub java_path: String,
    pub auto_install_java: bool,

    pub min_memory_mb: i32,
    pub max_memory_mb: i32,
    /// 额外 JVM 参数（全局 + 版本叠加后的）
    pub jvm_arguments: String,
    /// 额外游戏参数
    pub game_arguments: String,

    /// 是否版本隔离（决定 gameDir/game_assets）
    pub isolated: bool,

    pub server_address: String,
    pub fullscreen: bool,
    pub window_width: i32,
    pub window_height: i32,

    /// 0=普通 1=高 2=低
    pub process_priority: i32,
    pub pre_launch_command: String,
    pub wrapper_command: String,
    /// 每行 KEY=VALUE
    pub launch_environment: Vec<String>,

    pub use_bmclapi: bool,
    pub verify_files: bool,
    pub concurrency: i32,
    pub session_id: String,
}

/// 启动事件
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchEvent {
    /// phase | log | exit
    pub kind: String,
    /// preparing / downloading / extracting / buildingArgs / launching / running / exited / failed / cancelled
    pub phase: String,
    pub message: String,
    /// 0~1（downloading 阶段）
    pub progress: f64,
    /// 游戏输出行（kind=log）
    pub log_line: String,
    /// 退出码（kind=exit）
    pub exit_code: i32,
    /// 崩溃摘要（kind=exit 且非正常退出）
    pub crash_summary: String,
}

/// 取消/终止启动会话（下载阶段取消下载；游戏运行阶段终止进程）
pub async fn terminate_launch(session_id: String) {
    crate::util::cancel::CANCEL_REGISTRY.cancel(&session_id);
    crate::api::process::kill_all_owned().await;
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

pub async fn launch_game(options: LaunchOptions, sink: &Emitter) -> Result<()> {
    if !crate::util::cancel::CANCEL_REGISTRY.contains(&options.session_id) {
        crate::util::cancel::CANCEL_REGISTRY.create(&options.session_id);
    }
    let cancelled: CancelFlag = crate::util::cancel::CANCEL_REGISTRY.handle(&options.session_id);

    let result = run_launch(&options, sink, cancelled).await;
    match result {
        Ok(code) => {
            sink.send(&LaunchEvent {
                kind: "exit".into(),
                phase: if code == 0 { "exited".into() } else { "failed".into() },
                message: String::new(),
                progress: 0.0,
                log_line: String::new(),
                exit_code: code,
                crash_summary: String::new(),
            });
            crate::util::cancel::CANCEL_REGISTRY.dispose(&options.session_id);
            Ok(())
        }
        Err(e) => {
            let msg = e.to_string();
            let is_cancel = msg.contains("已取消");
            sink.send(&LaunchEvent {
                kind: "exit".into(),
                phase: if is_cancel { "cancelled".into() } else { "failed".into() },
                message: if is_cancel { "启动已取消".into() } else { msg.clone() },
                progress: 0.0,
                log_line: String::new(),
                exit_code: -1,
                crash_summary: String::new(),
            });
            if !is_cancel {
                crate::log_error!("Launch", "启动失败: {msg}");
            }
            crate::util::cancel::CANCEL_REGISTRY.dispose(&options.session_id);
            Err(anyhow!(msg))
        }
    }
}

fn emit(sink: &Emitter, phase: &str, message: &str) {
    sink.send(&LaunchEvent {
        kind: "phase".into(),
        phase: phase.into(),
        message: message.into(),
        progress: 0.0,
        log_line: String::new(),
        exit_code: 0,
        crash_summary: String::new(),
    });
}

fn emit_progress(sink: &Emitter, message: &str, progress: f64) {
    sink.send(&LaunchEvent {
        kind: "phase".into(),
        phase: "downloading".into(),
        message: message.into(),
        progress,
        log_line: String::new(),
        exit_code: 0,
        crash_summary: String::new(),
    });
}

async fn run_launch(
    options: &LaunchOptions,
    sink: &Emitter,
    cancelled: CancelFlag,
) -> Result<i32> {
    let started = std::time::Instant::now();
    let game_dir = PathBuf::from(&options.game_dir);
    let version_id = &options.version_id;
    anyhow::ensure!(
        game_dir
            .join("versions")
            .join(version_id)
            .join(format!("{version_id}.json"))
            .exists(),
        "版本 {version_id} 不存在（游戏目录 {}）",
        game_dir.display()
    );

    // ---------- 1. 账户 ----------
    emit(sink, "preparing", "准备账户...");
    let account = options
        .account
        .clone()
        .ok_or_else(|| anyhow!("尚未登录任何账户，请先在「账户」页添加"))?;
    crate::log_info!("Launch", "使用账户: {} ({})", account.name, account.account_type);

    // ---------- 2. 版本链 ----------
    emit(sink, "preparing", "解析版本依赖链...");
    let leaf_text = std::fs::read_to_string(
        game_dir.join("versions").join(version_id).join(format!("{version_id}.json")),
    )?;
    let leaf_json: Value = serde_json::from_str(&leaf_text).context("版本 JSON 解析失败")?;
    let chain = resolve_chain(&leaf_json, &game_dir);
    anyhow::ensure!(!chain.is_empty(), "版本链为空");
    let merged = merge_chain(&chain);
    crate::log_info!(
        "Launch",
        "版本链: {}",
        chain.iter().map(|c| c.id.clone()).collect::<Vec<_>>().join(" ← ")
    );

    // ---------- 3. 补全文件 ----------
    emit(sink, "downloading", "校验游戏文件...");
    complete_files(options, &game_dir, &merged, &chain, sink, &cancelled).await?;

    // ---------- 4. 解压 natives ----------
    emit(sink, "extracting", "解压本地库...");
    let natives_dir = extract_natives(&game_dir, &merged, version_id)?;

    // ---------- 5. Java ----------
    emit(sink, "buildingArgs", "选择 Java 运行时...");
    let required_java = merged.java_major.unwrap_or(8);
    let java_path = pick_java(options, required_java, sink).await?;
    crate::log_info!("Launch", "Java: {java_path}");

    // ---------- 5.5 内存安全校验（PCL2：超出物理内存 90% 拒绝启动） ----------
    let sys = crate::api::system::system_info();
    if options.max_memory_mb > 0 && (options.max_memory_mb as i64) > sys.total_memory_mb * 9 / 10 {
        bail!(
            "分配内存 {} MiB 超过物理内存 {} MiB 的 90%，可能导致游戏频繁交换崩溃。请在设置中调低内存。",
            options.max_memory_mb,
            sys.total_memory_mb
        );
    }

    // ---------- 6. 外置登录准备 ----------
    let mut javaagent_arg = String::new();
    if account.account_type == "yggdrasil" {
        emit(sink, "preparing", "准备外置登录（authlib-injector）...");
        let jar = crate::api::auth_api::ensure_authlib_injector().await?;
        let server = if account.yggdrasil_server.is_empty() {
            bail!("外置账户缺少认证服务器地址，请重新登录该账户");
        } else {
            account.yggdrasil_server.clone()
        };
        javaagent_arg = format!("-javaagent:{jar}={server}");
        crate::log_info!("Launch", "authlib-injector 注入: {server}");
    }

    // ---------- 7. 构建参数 ----------
    emit(sink, "buildingArgs", "构建启动参数...");
    let work_dir = if options.isolated {
        game_dir.join("versions").join(version_id)
    } else {
        game_dir.clone()
    };
    std::fs::create_dir_all(&work_dir)?;

    let (jvm_args, game_args) = build_arguments(
        options,
        &game_dir,
        &work_dir,
        &merged,
        &chain,
        &natives_dir,
        &javaagent_arg,
        &account,
    )?;

    // ---------- 8. 启动前命令 ----------
    let pre = options.pre_launch_command.trim();
    if !pre.is_empty() {
        emit(sink, "preparing", "执行启动前命令...");
        run_pre_launch(pre, &work_dir, version_id).await?;
    }

    // ---------- 9. spawn ----------
    emit(sink, "launching", "启动 Minecraft...");
    let mut spawn_args: Vec<String> = Vec::new();
    let wrapper = options.wrapper_command.trim().to_string();
    let program = if wrapper.is_empty() {
        java_path.clone()
    } else {
        spawn_args.push(java_path.clone());
        wrapper.clone()
    };
    spawn_args.extend(jvm_args.iter().cloned());
    spawn_args.push(merged.main_class.clone());
    spawn_args.extend(game_args.iter().cloned());

    let env = parse_env_lines(&options.launch_environment);
    let priority = match options.process_priority {
        1 => "high",
        2 => "low",
        _ => "normal",
    };

    crate::log_info!(
        "Launch",
        "启动进程: {program}\n工作目录: {}\n参数: {}{}",
        work_dir.display(),
        spawn_args.join(" "),
        if env.is_empty() { String::new() } else { format!("\n环境变量: {env:?}") }
    );

    let handle = crate::api::process::spawn_game_process(crate::api::process::ProcessSpawnConfig {
        program,
        args: spawn_args,
        working_dir: work_dir.to_string_lossy().into_owned(),
        env,
        process_priority: Some(priority.into()),
    })
    .await?;

    emit(sink, "running", "游戏运行中");

    // ---------- 10. 日志流（UI 事件 + 双路落盘） ----------
    let mut log_rx = crate::api::process::attach_output_stream_channel(handle)?;
    let stamp = crate::core::logging::chrono_now().replace([' ', ':'], "-");
    let game_log_path = work_dir
        .join("logs")
        .join(format!("fmcl-{version_id}-{stamp}.log"));
    let mirror_path = crate::core::paths::paths()
        .game_logs_dir
        .join(format!("game-{version_id}-{stamp}.log"));
    let _ = std::fs::create_dir_all(game_log_path.parent().unwrap());
    let _ = std::fs::create_dir_all(mirror_path.parent().unwrap());
    let mut log_writer = std::fs::File::create(&game_log_path).ok();
    let mut mirror_writer = std::fs::File::create(&mirror_path).ok();
    if let Some(f) = mirror_writer.as_mut() {
        let _ = std::io::Write::write_all(
            f,
            format!(
                "==== FMCL 0.1.0 游戏输出镜像 ====\n版本: {version_id}\n开始: {}\n\n",
                crate::core::logging::chrono_now()
            )
            .as_bytes(),
        );
    }

    let mut log_tail: Vec<String> = Vec::with_capacity(512);
    loop {
        tokio::select! {
            item = log_rx.recv() => {
                match item {
                    Some(event) => {
                        let line = event.line;
                        if !line.trim().is_empty() {
                            if event.stream == "stderr" {
                                crate::log_debug!("Game", "{line}");
                            }
                            sink.send(&LaunchEvent {
                                kind: "log".into(),
                                phase: "running".into(),
                                message: String::new(),
                                progress: 0.0,
                                log_line: line.clone(),
                                exit_code: 0,
                                crash_summary: String::new(),
                            });
                            if let Some(f) = log_writer.as_mut() {
                                let _ = std::io::Write::write_all(f, format!("{line}\n").as_bytes());
                            }
                            if let Some(f) = mirror_writer.as_mut() {
                                let _ = std::io::Write::write_all(f, format!("{line}\n").as_bytes());
                            }
                            log_tail.push(line);
                            if log_tail.len() > 800 {
                                log_tail.remove(0);
                            }
                        }
                    }
                    None => break, // 通道关闭 = 进程输出结束
                }
            }
            _ = tokio::time::sleep(std::time::Duration::from_millis(250)) => {
                if cancelled.load(Ordering::Relaxed) {
                    crate::api::process::kill_game_process(handle).await.ok();
                }
            }
        }
    }

    // 等待退出
    let exit_info = crate::api::process::wait_game_process(handle).await.unwrap_or(
        crate::api::process::ProcessExitInfo { pid: handle, exit_code: -1, success: false },
    );
    let exit_code = exit_info.exit_code;

    if let Some(f) = log_writer.as_mut() {
        let _ = std::io::Write::flush(f);
    }
    if let Some(f) = mirror_writer.as_mut() {
        let _ = std::io::Write::flush(f);
    }

    // ---------- 11. 退出分析 ----------
    let elapsed = started.elapsed().as_secs();
    let tail_text = log_tail.join("\n");
    let report = analyze_exit(exit_code, &tail_text, elapsed);
    if !report.is_normal {
        save_crash_reports(&game_dir, version_id, &tail_text, exit_code);
        crate::log_error!("Launch", "游戏异常退出 code={exit_code}: {}", report.summary);
        sink.send(&LaunchEvent {
            kind: "exit".into(),
            phase: "failed".into(),
            message: format!("游戏异常退出（代码 {exit_code}）"),
            progress: 0.0,
            log_line: String::new(),
            exit_code,
            crash_summary: report.summary.clone(),
        });
        bail!("游戏异常退出（代码 {exit_code}）：{}", report.summary);
    }
    crate::log_info!("Launch", "游戏正常退出 code={exit_code} 运行 {elapsed}s");
    Ok(exit_code)
}

// ---------------------------------------------------------------------------
// 启动前文件补全
// ---------------------------------------------------------------------------

async fn complete_files(
    options: &LaunchOptions,
    game_dir: &Path,
    merged: &MergedVersion,
    chain: &[ChainNode],
    sink: &Emitter,
    cancelled: &CancelFlag,
) -> Result<()> {
    let client = crate::util::http::build_public_client()?;
    let bmcl = options.use_bmclapi;

    // 客户端 jar（原版根缺失时补）
    if let Some(info) = &merged.vanilla_download {
        let vanilla_id = chain
            .iter()
            .find(|c| c.vanilla_download.is_some())
            .map(|c| c.id.clone())
            .unwrap_or_else(|| merged.id.clone());
        let jar_path = game_dir
            .join("versions")
            .join(&vanilla_id)
            .join(format!("{vanilla_id}.jar"));
        if !jar_path.exists() {
            let urls = client_urls_for(info, bmcl);
            download_with_fallback(&urls, &jar_path, info["sha1"].as_str(), info["size"].as_i64())
                .await
                .context("客户端 jar 补全失败")?;
        }
    }

    // 支持库
    let lib_items = collect_lib_items(Some(&merged.libraries_value), game_dir, bmcl);
    let missing: Vec<_> = if options.verify_files {
        lib_items.iter().filter(|it| !verify_existing(it)).cloned().collect()
    } else {
        lib_items.iter().filter(|it| !Path::new(&it.save_path).exists()).cloned().collect()
    };
    if !missing.is_empty() {
        crate::log_info!("Launch", "启动补全: 支持库 {} 个", missing.len());
        batch_download(
            missing,
            options.concurrency.max(1) as usize,
            cancelled,
            sink,
            "支持库",
            0.0,
            0.5,
        )
        .await?;
    }

    // 资源（assetIndex 来自继承链合并结果）
    let mut asset_lookup = serde_json::Map::new();
    if let Some(ai) = &merged.asset_index {
        asset_lookup.insert("assetIndex".into(), ai.clone());
    }
    let asset_items = collect_asset_items(&client, &Value::Object(asset_lookup), game_dir, bmcl)
        .await
        .unwrap_or_default();
    if !asset_items.is_empty() {
        crate::log_info!("Launch", "启动补全: 资源文件 {} 个", asset_items.len());
        batch_download(
            asset_items,
            options.concurrency.max(1) as usize,
            cancelled,
            sink,
            "资源文件",
            0.5,
            0.95,
        )
        .await?;
    }
    emit_progress(sink, "文件校验完成", 1.0);
    Ok(())
}

/// 批量下载（LaunchEvent 进度，100ms 节流）
async fn batch_download(
    items: Vec<crate::api::download::DownloadItem>,
    concurrency: usize,
    cancelled: &CancelFlag,
    sink: &Emitter,
    label: &str,
    from: f64,
    to: f64,
) -> Result<()> {
    if items.is_empty() {
        return Ok(());
    }
    let total = items.len() as i32;
    let counter = Arc::new(std::sync::Mutex::new((0i32, std::time::Instant::now())));
    let sink_c = sink.clone();
    let label_c = label.to_string();
    let (finished, failed) = crate::util::http::download_all(
        &items,
        concurrency,
        cancelled.clone(),
        None,
        move |_ok, _item, _err| {
            let mut g = counter.lock().unwrap();
            g.0 += 1;
            let now = std::time::Instant::now();
            if now.duration_since(g.1).as_millis() >= 100 || g.0 >= total {
                g.1 = now;
                let frac = from + (to - from) * (g.0 as f64 / total as f64);
                sink_c.send(&LaunchEvent {
                    kind: "phase".into(),
                    phase: "downloading".into(),
                    message: format!("下载{label_c}（{}/{}）", g.0, total),
                    progress: frac.clamp(0.0, 1.0),
                    log_line: String::new(),
                    exit_code: 0,
                    crash_summary: String::new(),
                });
            }
        },
    )
    .await;
    if cancelled.load(Ordering::Relaxed) {
        bail!("已取消");
    }
    if failed > 0 {
        bail!("{label}下载失败：{failed}/{total} 个文件未完成");
    }
    emit_progress(sink, &format!("{label}下载完成（{finished}/{total}）"), to);
    Ok(())
}

// ---------------------------------------------------------------------------
// natives
// ---------------------------------------------------------------------------

fn extract_natives(game_dir: &Path, merged: &MergedVersion, version_id: &str) -> Result<String> {
    let natives_dir = game_dir.join("versions").join(version_id).join("natives");
    std::fs::create_dir_all(&natives_dir)?;
    let libraries_dir = game_dir.join("libraries");
    let os_name = current_os();
    let arch = current_arch();

    let Some(libs) = merged.libraries_value.as_array() else {
        return Ok(natives_dir.to_string_lossy().into_owned());
    };
    for lib in libs {
        if lib["natives"].is_null() {
            continue;
        }
        if !lib_allowed(lib, os_name, arch) {
            continue;
        }
        // natives 分类器：字符串或 {os: classifier} 对象
        let classifier = match lib["natives"].as_str() {
            Some(c) => c.to_string(),
            None => lib["natives"][os_name]
                .as_str()
                .unwrap_or("")
                .to_string(),
        };
        if classifier.is_empty() {
            continue;
        }
        let classifier = classifier.replace("${arch}", "");
        let native = lib
            .pointer(&format!("/downloads/classifiers/{classifier}"))
            .cloned()
            .or_else(|| {
                // 无 downloads 元数据（旧版/Forge）：按坐标 + 分类器推导
                lib["name"].as_str().and_then(|name| {
                    coord_to_path_pub(&format!("{name}:{classifier}"))
                        .map(|rel| serde_json::json!({ "path": rel }))
                })
            });
        let Some(native) = native else { continue };
        let rel = native["path"].as_str().unwrap_or_default().to_string();
        if rel.is_empty() {
            continue;
        }
        let jar_path = libraries_dir.join(&rel);
        if !jar_path.exists() {
            bail!("natives 库缺失: {}", lib["name"].as_str().unwrap_or(&rel));
        }
        let excludes: Vec<String> = lib
            .pointer("/extract/exclude")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_else(|| vec!["META-INF/".to_string()]);
        crate::api::archive::extract_natives(
            jar_path.to_string_lossy().into_owned(),
            natives_dir.to_string_lossy().into_owned(),
            excludes,
            false,
        )
        .with_context(|| format!("解压 natives 失败: {rel}"))?;
    }
    Ok(natives_dir.to_string_lossy().into_owned())
}

pub(crate) fn current_os() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "osx"
    } else {
        "linux"
    }
}

pub(crate) fn current_arch() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "x86_64"
    }
}

// ---------------------------------------------------------------------------
// Java 选择
// ---------------------------------------------------------------------------

async fn pick_java(
    options: &LaunchOptions,
    required_major: i32,
    sink: &Emitter,
) -> Result<String> {
    let settings = settings::load_settings();

    // 1) 调用级覆盖（版本设置合并结果）
    if !options.java_path.trim().is_empty() {
        let p = options.java_path.trim().to_string();
        if Path::new(&p).exists() {
            return Ok(p);
        }
        bail!("指定的 Java 不存在: {p}");
    }
    // 2) 全局手动指定
    if !settings.java_path.trim().is_empty() {
        let p = settings.java_path.trim().to_string();
        if Path::new(&p).exists() {
            return Ok(p);
        }
        crate::log_warn!("Launch", "全局设置的 Java 不存在，回退自动选择: {p}");
    }

    // 3) 自动：扫描全部候选并探测（满足最低要求且尽量接近）
    let candidates = crate::api::java::find_java_candidates(settings.java_search_paths.clone());
    let mut best: Option<(i32, String)> = None;
    for c in candidates {
        let Ok(info) = crate::api::java::probe_java(c.clone()).await else {
            continue;
        };
        if !info.is_64bit || info.major_version < required_major {
            continue;
        }
        let closer = match &best {
            None => true,
            Some((b, _)) => info.major_version < *b,
        };
        if closer {
            best = Some((info.major_version, c));
        }
    }
    if let Some((_, path)) = best {
        return Ok(path);
    }

    // 4) 自动安装（PCL2：缺失时自动从 Adoptium 安装）
    if !options.auto_install_java || !settings.auto_install_java {
        bail!("未找到 Java {required_major} 运行时，请在设置中手动指定或允许自动安装");
    }
    emit(
        sink,
        "preparing",
        &format!("未检测到 Java {required_major}，正在自动安装（Adoptium）..."),
    );
    crate::log_info!("Launch", "自动安装 Java {required_major}");
    let runtime_root = crate::core::paths::paths().java_dir.clone();
    let session = format!("javainstall-{}", options.session_id);
    crate::util::cancel::CANCEL_REGISTRY.create(&session);
    let java_exe = crate::api::java_download::install_java_quiet(
        required_major,
        &runtime_root.to_string_lossy(),
        &session,
    )
    .await?;
    crate::util::cancel::CANCEL_REGISTRY.dispose(&session);
    Ok(java_exe.to_string_lossy().into_owned())
}

// ---------------------------------------------------------------------------
// 参数构建（移植自原 Dart LaunchArgumentsBuilder，语义一致）
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
fn build_arguments(
    options: &LaunchOptions,
    game_dir: &Path,
    work_dir: &Path,
    merged: &MergedVersion,
    chain: &[ChainNode],
    natives_dir: &str,
    javaagent_arg: &str,
    account: &LaunchAccount,
) -> Result<(Vec<String>, Vec<String>)> {
    let libraries_dir = game_dir.join("libraries");
    let assets_dir = game_dir.join("assets");
    let classpath_sep = if cfg!(target_os = "windows") { ";" } else { ":" };
    let os_name = current_os();
    let arch = current_arch();

    // ---- JVM ----
    let mut jvm: Vec<String> = Vec::new();
    jvm.push(format!("-Xms{}m", options.min_memory_mb.max(0)));
    jvm.push(format!("-Xmx{}m", options.max_memory_mb.max(0)));
    for a in split_args(&options.jvm_arguments) {
        jvm.push(a);
    }

    // classpath：全部适用库（natives 除外）+ 客户端 jar
    let mut cp: Vec<String> = Vec::new();
    if let Some(libs) = merged.libraries_value.as_array() {
        for lib in libs {
            if !lib_allowed(lib, os_name, arch) {
                continue;
            }
            if !lib["natives"].is_null() {
                continue;
            }
            let rel = lib
                .pointer("/downloads/artifact/path")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .or_else(|| lib["name"].as_str().and_then(coord_to_path_pub));
            if let Some(rel) = rel {
                cp.push(libraries_dir.join(rel).to_string_lossy().into_owned());
            }
        }
    }
    let mut client_jar = String::new();
    for node in chain.iter().rev() {
        let cand = game_dir
            .join("versions")
            .join(&node.id)
            .join(format!("{}.jar", node.id));
        if cand.exists() {
            client_jar = cand.to_string_lossy().into_owned();
            break;
        }
    }
    if client_jar.is_empty() {
        client_jar = game_dir
            .join("versions")
            .join(&merged.id)
            .join(format!("{}.jar", merged.id))
            .to_string_lossy()
            .into_owned();
    }
    cp.push(client_jar);

    let classpath = cp.join(classpath_sep);
    // 大 classpath：Windows 使用 @argfile 避免命令行长度限制
    let argfile_dir = work_dir.join(".fmcl");
    let _ = std::fs::create_dir_all(&argfile_dir);
    if cfg!(target_os = "windows") && classpath.len() > 8000 {
        let argfile = argfile_dir.join("classpath.txt");
        std::fs::write(&argfile, classpath.replace('\\', "/"))?;
        jvm.push(format!("-cp @{}", argfile.to_string_lossy().replace('\\', "/")));
    } else {
        jvm.push("-cp".into());
        jvm.push(classpath.clone());
    }

    // 版本 JSON jvm 模板
    let jvm_map: Vec<(String, String)> = vec![
        ("${natives_directory}".into(), natives_dir.into()),
        ("${launcher_name}".into(), "FMCL".into()),
        ("${launcher_version}".into(), "0.1.0".into()),
        ("${classpath}".into(), classpath.clone()),
        ("${classpath_separator}".into(), classpath_sep.into()),
        ("${arch}".into(), arch.into()),
    ];
    let flat_jvm = flatten_argument_rules(&merged.jvm_arguments, os_name, arch);
    jvm.extend(apply_template(&flat_jvm, &jvm_map));

    // log4j 配置（1.7+）
    if let Some(log_cfg) = &merged.logging_client {
        let arg = log_cfg["argument"].as_str().unwrap_or_default();
        if !arg.is_empty() {
            let name = log_cfg
                .pointer("/file/path")
                .and_then(|v| v.as_str())
                .and_then(|p| p.split('/').next_back())
                .unwrap_or("client-1.12.xml");
            let log_path = assets_dir.join("log_configs").join(name);
            jvm.push(arg.replace("${path}", &log_path.to_string_lossy()));
        }
    }

    // authlib-injector
    if !javaagent_arg.is_empty() {
        jvm.push(javaagent_arg.into());
    }

    // Windows 默认参数（对齐 PCL2/HMCL）
    if cfg!(target_os = "windows") {
        jvm.push("-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump".into());
    }
    jvm.push(format!("-Djava.library.path={natives_dir}"));

    // ---- 游戏 ----
    let assets_index_id = merged
        .asset_index
        .as_ref()
        .and_then(|a| a["id"].as_str())
        .map(|s| s.to_string())
        .or_else(|| merged.assets_id.clone())
        .unwrap_or_default();

    let server = options.server_address.trim().to_string();
    let (host, port) = split_host_port(&server);
    let quickplay_mp = if server.is_empty() || !mc_at_least_1_20(&merged.id) {
        String::new()
    } else {
        format!("{host}:{port}")
    };
    let game_map: Vec<(String, String)> = vec![
        ("${auth_player_name}".into(), account.name.clone()),
        ("${auth_uuid}".into(), account.uuid.clone()),
        ("${auth_access_token}".into(), account.access_token.clone()),
        ("${auth_xuid}".into(), String::new()),
        ("${clientid}".into(), "fmcl-client".into()),
        (
            "${auth_session}".into(),
            format!("token:{}:{}", account.access_token, account.uuid),
        ),
        (
            "${user_type}".into(),
            if account.account_type == "microsoft" { "msa".into() } else { "legacy".into() },
        ),
        ("${version_name}".into(), merged.id.clone()),
        ("${version_type}".into(), "FMCL".into()),
        ("${game_directory}".into(), work_dir.to_string_lossy().into_owned()),
        ("${assets_root}".into(), assets_dir.to_string_lossy().into_owned()),
        (
            "${game_assets}".into(),
            work_dir.join("assets").to_string_lossy().into_owned(),
        ),
        ("${assets_index_name}".into(), assets_index_id),
        ("${user_properties}".into(), "{}".into()),
        ("${resolution_width}".into(), options.window_width.to_string()),
        ("${resolution_height}".into(), options.window_height.to_string()),
        ("${quickPlayPath}".into(), String::new()),
        ("${quickPlaySingleplayer}".into(), String::new()),
        ("${quickPlayMultiplayer}".into(), quickplay_mp),
        ("${quickPlayRealms}".into(), String::new()),
    ];

    let mut game: Vec<String> = Vec::new();
    if let Some(mc_args) = merged.minecraft_arguments.as_deref() {
        if !mc_args.trim().is_empty() {
            let tokens: Vec<String> = mc_args.split(' ').map(|s| s.to_string()).collect();
            game.extend(apply_template(&tokens, &game_map));
        }
    }
    if game.is_empty() {
        let flat_game = flatten_argument_rules(&merged.game_arguments, os_name, arch);
        game.extend(apply_template(&flat_game, &game_map));
    }
    game = drop_dangling_flags(game);

    // 服务器自动加入
    if !server.is_empty() {
        let has_quickplay_token = merged
            .game_arguments
            .iter()
            .any(|v| v.as_str().map(|s| s.contains("quickPlayMultiplayer")).unwrap_or(false));
        let target = format!("{host}:{port}");
        let applied = game.windows(2).any(|w| w[0] == "--quickPlayMultiplayer" && w[1] == target);
        if !applied {
            let legacy = merged
                .minecraft_arguments
                .as_deref()
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false);
            if legacy || !has_quickplay_token {
                game.extend(["--server".into(), host.clone(), "--port".into(), port.clone()]);
            } else {
                game.extend(["--quickPlayMultiplayer".into(), target]);
            }
        }
    }

    // 全屏 / 分辨率
    if options.fullscreen {
        game.push("--fullscreen".into());
    } else if options.window_width > 0 && options.window_height > 0 {
        let modern = merged
            .game_arguments
            .iter()
            .any(|v| v.as_str().map(|s| s.contains("resolution_width")).unwrap_or(false))
            || merged
                .minecraft_arguments
                .as_deref()
                .map(|s| s.contains("width"))
                .unwrap_or(false);
        if !modern {
            game.extend([
                "--width".into(),
                options.window_width.to_string(),
                "--height".into(),
                options.window_height.to_string(),
            ]);
        }
    }

    // 用户自定义游戏参数
    for a in split_args(&options.game_arguments) {
        game.push(a);
    }

    Ok((jvm, game))
}

/// 展开带规则的 arguments 数组（字符串原样，规则通过时展开 value）
fn flatten_argument_rules(items: &[Value], os_name: &str, arch: &str) -> Vec<String> {
    let mut out = Vec::new();
    for item in items {
        match item {
            Value::String(s) => out.push(s.clone()),
            Value::Object(o) => {
                let rules = o.get("rules").and_then(|r| r.as_array());
                if rules_allowed(rules, os_name, arch) {
                    match o.get("value") {
                        Some(Value::String(s)) => out.push(s.clone()),
                        Some(Value::Array(a)) => {
                            for v in a {
                                if let Some(s) = v.as_str() {
                                    out.push(s.to_string());
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn rules_allowed(rules: Option<&Vec<Value>>, os_name: &str, arch: &str) -> bool {
    let Some(rules) = rules else { return true };
    if rules.is_empty() {
        return true;
    }
    let mut allowed = false;
    for r in rules {
        let os = &r["os"];
        let name_ok = os["name"].as_str().map(|n| n == os_name).unwrap_or(true);
        let arch_ok = os["arch"].as_str().map(|a| a == arch).unwrap_or(true);
        if !(name_ok && arch_ok) {
            continue;
        }
        match r["action"].as_str() {
            Some("allow") => allowed = true,
            Some("disallow") => allowed = false,
            _ => {}
        }
    }
    allowed
}

fn apply_template(input: &[String], map: &[(String, String)]) -> Vec<String> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        let arg = &input[i];
        let is_token = arg.starts_with("${") && arg.ends_with('}');
        let value = map
            .iter()
            .find(|(k, _)| k == arg)
            .map(|(_, v)| v.clone())
            .unwrap_or_default();
        if is_token {
            if !value.is_empty() {
                out.push(value);
                if i + 1 < input.len()
                    && !input[i + 1].starts_with("--")
                    && !input[i + 1].starts_with("${")
                {
                    i += 2;
                    continue;
                }
            } else if i + 1 < input.len()
                && !input[i + 1].starts_with("--")
                && !input[i + 1].starts_with("${")
            {
                // 空值 token：跳过 token 及其悬挂值
                i += 2;
                continue;
            }
        } else {
            let mut replaced = arg.clone();
            for (k, v) in map {
                replaced = replaced.replace(k.as_str(), v);
            }
            out.push(replaced);
        }
        i += 1;
    }
    out
}

const VALUE_FLAGS: [&str; 4] = [
    "--quickPlayPath",
    "--quickPlaySingleplayer",
    "--quickPlayMultiplayer",
    "--quickPlayRealms",
];

fn drop_dangling_flags(input: Vec<String>) -> Vec<String> {
    let mut out = Vec::with_capacity(input.len());
    for (i, a) in input.iter().enumerate() {
        if VALUE_FLAGS.contains(&a.as_str()) && (i + 1 >= input.len() || input[i + 1].starts_with("--")) {
            continue;
        }
        out.push(a.clone());
    }
    out
}

fn split_host_port(address: &str) -> (String, String) {
    if address.is_empty() {
        return (String::new(), String::new());
    }
    match address.rfind(':') {
        None => (address.to_string(), "25565".into()),
        Some(0) => (address.to_string(), "25565".into()),
        Some(last) => {
            let port_part = &address[last + 1..];
            match port_part.parse::<u32>() {
                Ok(p) if (1..=65535).contains(&p) => {
                    (address[..last].to_string(), port_part.to_string())
                }
                _ => (address.to_string(), "25565".into()),
            }
        }
    }
}

fn mc_at_least_1_20(version_id: &str) -> bool {
    let bytes = version_id.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'1' && i + 1 < bytes.len() && bytes[i + 1] == b'.' {
            let rest = &version_id[i + 2..];
            let minor: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !minor.is_empty() {
                return minor.parse::<i32>().map(|m| m >= 20).unwrap_or(false);
            }
        }
    }
    false
}

/// 拆分用户输入参数（支持引号包裹）
fn split_args(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    for c in input.chars() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else {
                    cur.push(c);
                }
            }
            None => match c {
                '"' | '\'' => quote = Some(c),
                c if c.is_whitespace() => {
                    if !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                    }
                }
                c => cur.push(c),
            },
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn parse_env_lines(lines: &[String]) -> std::collections::HashMap<String, String> {
    let mut env = std::collections::HashMap::new();
    for line in lines {
        if let Some(idx) = line.find('=') {
            let (k, v) = line.split_at(idx);
            let k = k.trim();
            if k.is_empty() {
                continue;
            }
            env.insert(k.to_string(), v[1..].trim().to_string());
        }
    }
    env
}

async fn run_pre_launch(command: &str, work_dir: &Path, version_id: &str) -> Result<()> {
    let resolved = command
        .replace("$VERSION_ID", version_id)
        .replace("$GAME_DIR", &work_dir.to_string_lossy());
    crate::log_info!("Launch", "执行启动前命令: {resolved}");
    #[cfg(target_os = "windows")]
    let (program, args): (&str, Vec<String>) =
        ("cmd.exe", vec!["/d".into(), "/c".into(), resolved.clone()]);
    #[cfg(not(target_os = "windows"))]
    let (program, args): (&str, Vec<String>) = ("sh", vec!["-c".into(), resolved.clone()]);
    let output = tokio::process::Command::new(program)
        .args(&args)
        .current_dir(work_dir)
        .output()
        .await
        .map_err(|e| anyhow!("启动前命令执行失败: {e}"))?;
    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr).trim().to_string();
        bail!(
            "启动前命令执行失败（退出码 {:?}）{}",
            output.status.code(),
            if err.is_empty() { String::new() } else { format!(": {err}") }
        );
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 退出分析与崩溃报告
// ---------------------------------------------------------------------------

struct ExitReport {
    is_normal: bool,
    summary: String,
}

fn analyze_exit(code: i32, log_tail: &str, elapsed_secs: u64) -> ExitReport {
    if code == 0 {
        return ExitReport { is_normal: true, summary: String::new() };
    }
    let lower = log_tail.to_ascii_lowercase();
    let known: &[(&str, &str)] = &[
        ("outofmemoryerror", "内存不足（OutOfMemoryError）：请调整内存分配后重试"),
        ("out of memory", "内存不足：请调整内存分配或关闭其它程序"),
        ("unsupportedclassversionerror", "Java 版本不匹配：该版本需要更高版本的 Java 运行时"),
        ("classnotfoundexception", "文件缺失或库损坏：请执行「补全文件」，必要时重装该版本"),
        ("noclassdeffounderror", "库文件损坏或缺失：请执行「补全文件」"),
        ("nosuchmethoderror", "模组与游戏/加载器版本不匹配，请检查模组兼容性"),
        ("gl_type", "显卡/OpenGL 初始化失败：请更新显卡驱动"),
        ("failed to create a window", "无法创建窗口：请检查显卡驱动与分辨率设置"),
        ("access denied", "权限不足：请以管理员运行或检查目录权限"),
        ("exception in thread \"main\"", "主线程异常：请查看日志末尾定位"),
    ];
    for (needle, hint) in known {
        if lower.contains(needle) {
            return ExitReport { is_normal: false, summary: hint.to_string() };
        }
    }
    if elapsed_secs < 5 {
        return ExitReport {
            is_normal: false,
            summary: "启动数秒内即崩溃：多为 Java 版本不匹配或文件损坏，请检查 Java 与「补全文件」".into(),
        };
    }
    ExitReport {
        is_normal: false,
        summary: "未知错误，请查看游戏日志末尾定位".into(),
    }
}

fn save_crash_reports(game_dir: &Path, version_id: &str, log_tail: &str, exit_code: i32) {
    let stamp = crate::core::logging::chrono_now().replace([' ', ':', '-'], "");
    let text = format!(
        "==== FMCL 崩溃报告 ====\n版本: {version_id}\n退出码: {exit_code}\n时间: {}\n\n{log_tail}\n",
        crate::core::logging::chrono_now()
    );
    let game_report = game_dir
        .join("crash-reports")
        .join(format!("fmcl-{version_id}-{stamp}.log"));
    if let Some(p) = game_report.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let _ = std::fs::write(&game_report, &text);
    let mirror = crate::core::paths::paths()
        .crash_reports_dir
        .join(format!("fmcl-{version_id}-{stamp}.log"));
    let _ = std::fs::write(&mirror, &text);
}
