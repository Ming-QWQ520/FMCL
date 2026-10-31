//! 方法分发表：method 名 → Rust 业务函数。
//!
//! - 命名与参数键与 Dart 桥接层一一对应（参数键为 camelCase）。
//! - 普通方法返回可序列化值；流式方法通过 [`Emitter`] 推送过程事件，
//!   最终返回值作为流的结束标记。
//!
//! Flutter 侧所有交互都收敛到本表，业务实现分布在 `api/*` 与 `core/*`。

use crate::bridge::Emitter;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};

type R = Result<Value>;

/// 提取字符串参数
fn get_str(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string()
}

/// 提取可选字符串参数
fn get_opt_str(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// 提取 i32 参数
fn get_i32(v: &Value, key: &str) -> i32 {
    v.get(key).and_then(|x| x.as_i64()).unwrap_or(0) as i32
}

/// 提取 bool 参数
fn get_bool(v: &Value, key: &str) -> bool {
    v.get(key).and_then(|x| x.as_bool()).unwrap_or(false)
}

/// 提取字符串数组参数
fn get_str_vec(v: &Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(|x| x.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// 提取结构体参数（camelCase → 结构体，需目标结构体有对应 serde 命名）
fn get_struct<T: serde::de::DeserializeOwned>(v: &Value, key: &str) -> Result<T> {
    let node = v.get(key).ok_or_else(|| anyhow!("缺少参数 {key}"))?;
    serde_json::from_value(node.clone()).map_err(|e| anyhow!("参数 {key} 解析失败: {e}"))
}

fn to_json<T: serde::Serialize>(value: &T) -> R {
    serde_json::to_value(value).map_err(|e| anyhow!("序列化失败: {e}"))
}

pub async fn dispatch(method: &str, v: Value, em: Emitter) -> R {
    match method {
        // ------------------------------------------------------------------
        // 应用与日志
        // ------------------------------------------------------------------
        "init_app" => to_json(&crate::api::app::init_app()?),
        "read_recent_logs" => to_json(&crate::api::app::read_recent_logs(get_i32(&v, "maxLines"))?),
        "list_log_files" => to_json(&crate::api::app::list_log_files()?),
        "read_log_file" => to_json(&crate::api::app::read_log_file(
            get_str(&v, "path"),
            get_i32(&v, "maxLines"),
        )?),
        "open_path" => {
            crate::api::app::open_path(get_str(&v, "path"))?;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 设置
        // ------------------------------------------------------------------
        "get_settings" => to_json(&crate::api::settings_api::get_settings()),
        "save_settings" => {
            crate::api::settings_api::save_settings(get_struct(&v, "settings")?)?;
            Ok(Value::Null)
        }
        "effective_game_directory" => {
            Ok(json!(crate::api::settings_api::effective_game_directory()))
        }
        "set_last_version" => {
            crate::api::settings_api::set_last_version(get_str(&v, "versionId"))?;
            Ok(Value::Null)
        }
        "set_last_account" => {
            crate::api::settings_api::set_last_account(get_str(&v, "accountId"))?;
            Ok(Value::Null)
        }
        "get_version_settings" => to_json(&crate::api::settings_api::get_version_settings(
            get_str(&v, "gameDir"),
            get_str(&v, "versionId"),
        )),
        "save_version_settings" => {
            crate::api::settings_api::save_version_settings(
                get_str(&v, "gameDir"),
                get_str(&v, "versionId"),
                get_struct(&v, "settings")?,
            )?;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 账户
        // ------------------------------------------------------------------
        "list_accounts" => to_json(&crate::api::auth_api::list_accounts()?),
        "get_current_account" => to_json(&crate::api::auth_api::get_current_account()?),
        "add_offline_account" => to_json(&crate::api::auth_api::add_offline_account(
            get_str(&v, "name"),
        )?),
        "select_account" => {
            crate::api::auth_api::select_account(get_str(&v, "id"))?;
            Ok(Value::Null)
        }
        "remove_account" => {
            crate::api::auth_api::remove_account(get_str(&v, "id"))?;
            Ok(Value::Null)
        }
        "save_account" => {
            crate::api::auth_api::save_account(get_struct(&v, "account")?)?;
            Ok(Value::Null)
        }
        "microsoft_login" => {
            let account = crate::api::auth_api::microsoft_login(&em).await?;
            to_json(&account)
        }
        "microsoft_refresh" => {
            let account = crate::api::auth_api::microsoft_refresh(get_str(&v, "refreshToken")).await?;
            to_json(&account)
        }
        "yggdrasil_login" => {
            let session = crate::api::auth_api::yggdrasil_login(
                get_str(&v, "serverUrl"),
                get_str(&v, "username"),
                get_str(&v, "password"),
            )
            .await?;
            to_json(&session)
        }
        "save_yggdrasil_account" => {
            let account = crate::api::auth_api::save_yggdrasil_account(
                get_str(&v, "apiRoot"),
                get_str(&v, "accessToken"),
                get_str(&v, "clientToken"),
                get_str(&v, "profileId"),
                get_str(&v, "profileName"),
            )?;
            to_json(&account)
        }
        "yggdrasil_validate_or_refresh" => {
            let token = crate::api::auth_api::yggdrasil_validate_or_refresh(
                get_str(&v, "apiRoot"),
                get_str(&v, "accessToken"),
                get_str(&v, "clientToken"),
            )
            .await?;
            Ok(json!(token))
        }
        "ensure_authlib_injector" => Ok(json!(crate::api::auth_api::ensure_authlib_injector().await?)),

        // ------------------------------------------------------------------
        // 版本管理
        // ------------------------------------------------------------------
        "scan_local_versions" => to_json(&crate::api::versions_api::scan_local_versions(
            get_str(&v, "gameDir"),
        )?),
        "import_external_version" => {
            let id = crate::api::versions_api::import_external_version(
                get_str(&v, "gameDir"),
                get_str(&v, "sourceDir"),
                get_str(&v, "newName"),
            )?;
            Ok(json!(id))
        }
        "delete_version" => {
            crate::api::versions_api::delete_version(get_str(&v, "gameDir"), get_str(&v, "versionId"))?;
            Ok(Value::Null)
        }
        "rename_version" => {
            crate::api::versions_api::rename_version(
                get_str(&v, "gameDir"),
                get_str(&v, "versionId"),
                get_str(&v, "newName"),
            )?;
            Ok(Value::Null)
        }
        "copy_version" => {
            crate::api::versions_api::copy_version(
                get_str(&v, "gameDir"),
                get_str(&v, "versionId"),
                get_str(&v, "newName"),
            )?;
            Ok(Value::Null)
        }
        "complete_version" => {
            crate::api::versions_api::complete_version(
                get_str(&v, "gameDir"),
                get_str(&v, "versionId"),
                get_bool(&v, "bmclapiFirst"),
                get_i32(&v, "concurrency"),
                get_str(&v, "sessionId"),
                &em,
            )
            .await?;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 清单与加载器
        // ------------------------------------------------------------------
        "fetch_remote_versions" => to_json(
            &crate::api::manifest_api::fetch_remote_versions(get_bool(&v, "bmclapiFirst")).await?,
        ),
        "fetch_loader_versions" => to_json(
            &crate::api::manifest_api::fetch_loader_versions(
                get_str(&v, "loader"),
                get_str(&v, "mcVersion"),
                get_bool(&v, "bmclapiFirst"),
            )
            .await?,
        ),

        // ------------------------------------------------------------------
        // 安装 / 整合包
        // ------------------------------------------------------------------
        "install_combined" => {
            let request = get_struct(&v, "request")?;
            let id = crate::api::install::install_combined(request, &em).await?;
            Ok(json!(id))
        }
        "install_modpack" => {
            let name = crate::api::content_api::install_modpack(
                get_str(&v, "zipPath"),
                get_str(&v, "gameDir"),
                get_str(&v, "instanceName"),
                get_str(&v, "javaPath"),
                get_bool(&v, "useBmclapi"),
                get_i32(&v, "concurrency"),
                get_str(&v, "sessionId"),
                &em,
            )
            .await?;
            Ok(json!(name))
        }
        "parse_modpack" => {
            let manifest = crate::api::content_api::parse_modpack(get_str(&v, "zipPath")).await?;
            to_json(&manifest)
        }

        // ------------------------------------------------------------------
        // 内容下载（Modrinth 等）
        // ------------------------------------------------------------------
        "search_content" => to_json(
            &crate::api::content_api::search_content(
                get_str(&v, "query"),
                get_str(&v, "category"),
                get_str(&v, "mcVersion"),
                get_str(&v, "loader"),
                get_i32(&v, "index"),
            )
            .await?,
        ),
        "list_project_files" => to_json(
            &crate::api::content_api::list_project_files(get_str(&v, "projectId")).await?,
        ),
        "install_content_file" => {
            let path = crate::api::content_api::install_content_file(
                get_str(&v, "gameDir"),
                get_str(&v, "versionId"),
                get_str(&v, "category"),
                get_str(&v, "downloadUrl"),
                get_str(&v, "filename"),
                get_str(&v, "sessionId"),
            )
            .await?;
            Ok(json!(path))
        }
        "list_installed_contents" => to_json(&crate::api::content_api::list_installed_contents(
            get_str(&v, "gameDir"),
            get_str(&v, "versionId"),
            get_str(&v, "category"),
        )?),
        "delete_content_file" => {
            crate::api::content_api::delete_content_file(get_str(&v, "path"))?;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // Java
        // ------------------------------------------------------------------
        "detect_javas" => {
            to_json(&crate::api::java_api::detect_javas(get_str_vec(&v, "extraDirs")).await?)
        }
        "validate_java" => to_json(&crate::api::java_api::validate_java(get_str(&v, "javaPath")).await?),
        "download_java" => {
            crate::api::java_api::download_java(get_i32(&v, "major"), get_str(&v, "sessionId"), &em)
                .await?;
            Ok(Value::Null)
        }
        "remove_java" => {
            crate::api::java_api::remove_java(get_i32(&v, "major"))?;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 启动
        // ------------------------------------------------------------------
        "launch_game" => {
            let options = get_struct(&v, "options")?;
            crate::api::launch_api::launch_game(options, &em).await?;
            Ok(Value::Null)
        }
        "terminate_launch" => {
            crate::api::launch_api::terminate_launch(get_str(&v, "sessionId")).await;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 下载引擎（通用批量下载）
        // ------------------------------------------------------------------
        "create_download_session" => {
            Ok(json!(crate::api::download::create_download_session()))
        }
        "cancel_download" => {
            crate::api::download::cancel_download(get_str(&v, "sessionId"));
            Ok(Value::Null)
        }
        "dispose_download_session" => {
            crate::api::download::dispose_download_session(get_str(&v, "sessionId"));
            Ok(Value::Null)
        }
        "download_batch" => {
            let items: Vec<crate::api::download::DownloadItem> = v
                .get("items")
                .and_then(|x| x.as_array())
                .ok_or_else(|| anyhow!("缺少参数 items"))?
                .iter()
                .map(|it| {
                    serde_json::from_value(it.clone())
                        .map_err(|e| anyhow!("下载条目解析失败: {e}"))
                })
                .collect::<Result<Vec<_>>>()?;
            crate::api::download::download_batch(
                items,
                get_i32(&v, "concurrency"),
                get_str(&v, "sessionId"),
                get_opt_str(&v, "userAgent"),
                &em,
            )
            .await;
            Ok(Value::Null)
        }

        // ------------------------------------------------------------------
        // 系统与服务查询
        // ------------------------------------------------------------------
        "system_info" => to_json(&crate::api::system::system_info()),
        "ping_server" => {
            let status = crate::api::server_ping::ping_server(
                get_str(&v, "host"),
                get_i32(&v, "port"),
                v.get("timeoutMs").and_then(|x| x.as_i64()).unwrap_or(5000),
            )
            .await?;
            to_json(&status)
        }
        "file_sha1" => Ok(json!(crate::api::hash::file_sha1(get_str(&v, "path"))?)),
        "file_md5" => Ok(json!(crate::api::hash::file_md5(get_str(&v, "path"))?)),
        "file_sha256" => Ok(json!(crate::api::hash::file_sha256(get_str(&v, "path"))?)),
        "extract_all" => {
            let n = crate::api::archive::extract_all(get_str(&v, "zipPath"), get_str(&v, "destDir"))?;
            Ok(json!(n))
        }

        _ => Err(anyhow!("未知方法: {method}")),
    }
}
