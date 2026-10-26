//! Java 运行时自动安装（借鉴 PCL2 2.13 的 Java 管理思路）。
//!
//! 数据源：Adoptium (Eclipse Temurin) API v3。
//! 流程：查询最新 JRE 资产 → 走 Rust 下载引擎单线程下载 → SHA256 校验
//! → 解压（Windows zip / Linux & macOS tar.gz）→ 扁平化目录 → 返回安装路径。
//!
//! 安装位置由 Dart 侧传入（通常为 `<gameDir>/runtime/java-<major>`），
//! 安装完成后 Dart 侧调用 `probe_java` 验证。

use crate::util::cancel::CANCEL_REGISTRY;
use anyhow::{anyhow, bail, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;

/// Adoptium 资产信息（已筛选出最佳下载项）
#[derive(Debug, Clone, serde::Serialize)]
pub struct AdoptiumAsset {
    /// 下载 URL
    pub download_url: String,
    /// 文件名（如 OpenJDK21U-jre_x64_linux_hotspot_21.0.5_11.tar.gz）
    pub file_name: String,
    /// SHA256 校验和（小写十六进制）
    pub sha256: String,
    /// 字节大小
    pub size: i64,
    /// 压缩格式："zip" | "tar.gz"
    pub format: String,
    /// Java 版本号
    pub major_version: i32,
    /// 完整版本字符串
    pub version_string: String,
    /// JVM 供应商
    pub vendor: String,
}

#[derive(Debug, Deserialize)]
struct AdoptiumResponse {
    binaries: Vec<AdoptiumBinary>,
    vendor: AdoptiumVendor,
    version_data: AdoptiumVersionData,
}

#[derive(Debug, Deserialize)]
struct AdoptiumBinary {
    #[serde(rename = "package")]
    package: AdoptiumPackage,
    image_type: String,
    #[allow(dead_code)]
    architecture: String,
}

#[derive(Debug, Deserialize)]
struct AdoptiumPackage {
    name: String,
    link: String,
    #[allow(dead_code)]
    #[serde(rename = "checksum_link")]
    checksum_link: Option<String>,
    sha256_checksum: Option<String>,
    size: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct AdoptiumVendor {
    name: String,
}

#[derive(Debug, Deserialize)]
struct AdoptiumVersionData {
    major: i32,
    #[serde(rename = "openjdk_version")]
    openjdk_version: Option<String>,
    semver: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct JavaInstallProgress {
    /// "query" | "download" | "verify" | "extract" | "finalize" | "done" | "failed"
    pub phase: String,
    pub message: String,
    /// 0~1，None 表示不确定
    pub progress: Option<f64>,
}

/// 查询指定主版本的最新 Adoptium JRE 资产。
///
/// 仅匹配当前平台 + x64/aarch64 架构 + jre 镜像类型。
pub async fn adoptium_latest_jre(major: i32) -> Result<AdoptiumAsset> {
    let (os, arch) = platform_keys();
    let url = format!(
        "https://api.adoptium.net/v3/assets/latest/{major}/hotspot?os={os}&architecture={arch}&image_type=jre"
    );
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let resp = client.get(&url).send().await?.error_for_status()?;
    let list: Vec<AdoptiumResponse> = resp.json().await?;
    let entry = list
        .first()
        .ok_or_else(|| anyhow!("Adoptium 未返回 Java {major} 的可用资产"))?;

    // 优先 zip（Windows），其次 tar.gz
    let wanted_ext = if os == "windows" { ".zip" } else { ".tar.gz" };
    let binary = entry
        .binaries
        .iter()
        .find(|b| b.image_type == "jre" && b.package.name.ends_with(wanted_ext))
        .or_else(|| {
            entry.binaries.iter().find(|b| {
                b.image_type == "jre"
                    && (b.package.name.ends_with(".zip") || b.package.name.ends_with(".tar.gz"))
            })
        })
        .ok_or_else(|| anyhow!("Adoptium 资产中未找到 JRE 压缩包"))?;

    let format = if binary.package.name.ends_with(".zip") {
        "zip"
    } else {
        "tar.gz"
    };

    Ok(AdoptiumAsset {
        download_url: binary.package.link.clone(),
        file_name: binary.package.name.clone(),
        sha256: binary
            .package
            .sha256_checksum
            .clone()
            .unwrap_or_default()
            .to_lowercase(),
        size: binary.package.size.unwrap_or(0),
        format: format.into(),
        major_version: entry.version_data.major,
        version_string: entry
            .version_data
            .openjdk_version
            .clone()
            .or_else(|| entry.version_data.semver.clone())
            .unwrap_or_else(|| format!("java-{major}")),
        vendor: format!("Eclipse {}", entry.vendor.name),
    })
}

/// 安装 Java 运行时到 `runtime_root` 目录。
///
/// 返回 java 可执行文件路径。进度经事件流回传。
/// 依赖 Dart 侧先建立下载会话（复用取消注册表）。
pub async fn install_java(
    major: i32,
    runtime_root: String,
    session_id: String,
    sink: crate::frb_generated::StreamSink<JavaInstallProgress>,
) {
    let result = install_java_inner(major, &runtime_root, &session_id, &sink).await;
    match result {
        Ok(_) => {
            let _ = sink.add(JavaInstallProgress {
                phase: "done".into(),
                message: "Java 安装完成".into(),
                progress: Some(1.0),
            });
        }
        Err(e) => {
            let _ = sink.add(JavaInstallProgress {
                phase: "failed".into(),
                message: format!("Java 安装失败: {e}"),
                progress: None,
            });
        }
    }
}

async fn install_java_inner(
    major: i32,
    runtime_root: &str,
    session_id: &str,
    sink: &crate::frb_generated::StreamSink<JavaInstallProgress>,
) -> Result<()> {
    let cancelled = CANCEL_REGISTRY.handle(session_id);

    // 1. 查询资产
    let _ = sink.add(JavaInstallProgress {
        phase: "query".into(),
        message: format!("查询 Adoptium Java {major} 资产..."),
        progress: None,
    });
    let asset = adoptium_latest_jre(major).await?;

    // 2. 下载（单文件，直读流式落盘，支持取消）
    let root = PathBuf::from(runtime_root);
    std::fs::create_dir_all(&root)?;
    let tmp_path = root.join(format!("{}.download", asset.file_name));
    let final_path = root.join(&asset.file_name);

    let _ = sink.add(JavaInstallProgress {
        phase: "download".into(),
        message: format!("下载 {}（{:.1} MB）...", asset.file_name, asset.size as f64 / 1e6),
        progress: Some(0.0),
    });

    // 已有完整下载则跳过（幂等重试）
    if !final_path.exists() || !verify_sha256(&final_path, &asset.sha256).unwrap_or(false) {
        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(15))
            .timeout(std::time::Duration::from_secs(1800))
            .build()?;
        let mut last_emit = tokio::time::Instant::now();
        {
            let resp = client
                .get(&asset.download_url)
                .send()
                .await?
                .error_for_status()?;
            let total = resp.content_length().unwrap_or(asset.size.max(0) as u64);
            let mut file = tokio::fs::File::create(&tmp_path).await?;
            use futures_util::StreamExt;
            use tokio::io::AsyncWriteExt;
            let mut stream = resp.bytes_stream();
            let mut downloaded: u64 = 0;
            while let Some(chunk) = stream.next().await {
                if cancelled.load(Ordering::Relaxed) {
                    let _ = tokio::fs::remove_file(&tmp_path).await;
                    bail!("已取消");
                }
                let chunk = chunk?;
                file.write_all(&chunk).await?;
                downloaded += chunk.len() as u64;
                // 150ms 节流上报
                if last_emit.elapsed().as_millis() >= 150 {
                    last_emit = tokio::time::Instant::now();
                    let _ = sink.add(JavaInstallProgress {
                        phase: "download".into(),
                        message: format!(
                            "下载中 {:.1}/{:.1} MB",
                            downloaded as f64 / 1e6,
                            total as f64 / 1e6
                        ),
                        progress: if total > 0 {
                            Some(downloaded as f64 / total as f64 * 0.9)
                        } else {
                            None
                        },
                    });
                }
            }
            file.flush().await?;
            file.sync_all().await?;
        }

        // 3. 校验
        let _ = sink.add(JavaInstallProgress {
            phase: "verify".into(),
            message: "校验 SHA256...".into(),
            progress: Some(0.92),
        });
        if !asset.sha256.is_empty() && !verify_sha256(&tmp_path, &asset.sha256)? {
            let _ = tokio::fs::remove_file(&tmp_path).await;
            bail!("SHA256 校验失败（下载可能损坏）");
        }
        std::fs::rename(&tmp_path, &final_path)?;
    }

    // 4. 解压到 staging 再原子就位（借鉴 PCL.Core IO：先写临时，成功后改名）
    let staging = root.join(format!(".staging-{major}"));
    if staging.exists() {
        std::fs::remove_dir_all(&staging)?;
    }
    std::fs::create_dir_all(&staging)?;
    let _ = sink.add(JavaInstallProgress {
        phase: "extract".into(),
        message: "解压运行时...".into(),
        progress: Some(0.95),
    });
    if asset.format == "zip" {
        extract_zip(&final_path, &staging)?;
    } else {
        extract_targz(&final_path, &staging)?;
    }

    // 5. 扁平化（Adoptium 包内有一层 jdk-21.0.x+NN 目录）
    let java_home = flatten_single_dir(&staging)?;
    let java_exe = java_home
        .join("bin")
        .join(if cfg!(windows) { "java.exe" } else { "java" });
    if !java_exe.exists() {
        bail!("解压后未找到 java 可执行文件: {}", java_home.display());
    }

    // 就位：目标目录 = root/java-<major>
    let target = root.join(format!("java-{major}"));
    if target.exists() {
        std::fs::remove_dir_all(&target)?;
    }
    std::fs::rename(&java_home, &target)?;
    let _ = std::fs::remove_dir_all(&staging);
    let _ = std::fs::remove_file(&final_path); // 清理压缩包省空间

    let _ = sink.add(JavaInstallProgress {
        phase: "finalize".into(),
        message: format!("已安装到 {}", target.display()),
        progress: Some(0.99),
    });
    Ok(())
}

/// 平台标识（Adoptium API 用）
fn platform_keys() -> (&'static str, &'static str) {
    let os = match std::env::consts::OS {
        "windows" => "windows",
        "macos" => "mac",
        _ => "linux",
    };
    // 默认 x64；aarch64 主机自动切换
    let arch = if std::env::consts::ARCH == "aarch64" {
        "aarch64"
    } else {
        "x64"
    };
    (os, arch)
}

fn verify_sha256(path: &Path, expect: &str) -> Result<bool> {
    if expect.is_empty() {
        return Ok(true);
    }
    use sha2::Digest;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = sha2::Sha256::new();
    let mut buf = [0u8; 256 * 1024];
    loop {
        let n = std::io::Read::read(&mut file, &mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let actual = hex::encode(hasher.finalize());
    Ok(actual.eq_ignore_ascii_case(expect))
}

fn extract_zip(zip_path: &Path, dest: &Path) -> Result<()> {
    let file = std::fs::File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.name().to_string();
        let out = crate::api::archive::safe_join(dest, &name)?;
        if entry.is_dir() {
            std::fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out_file = std::fs::File::create(&out)?;
        std::io::copy(&mut entry, &mut out_file)?;
    }
    Ok(())
}

fn extract_targz(tar_path: &Path, dest: &Path) -> Result<()> {
    let gz = std::fs::File::open(tar_path)?;
    let decoder = flate2::read::GzDecoder::new(gz);
    let mut archive = tar::Archive::new(decoder);
    archive.set_preserve_permissions(false);
    archive.unpack(dest)?;
    Ok(())
}

/// 若 dest 下只有一个目录则返回该目录，否则返回 dest 本身
fn flatten_single_dir(dest: &Path) -> Result<PathBuf> {
    let entries: Vec<_> = std::fs::read_dir(dest)?
        .filter_map(|e| e.ok())
        .collect();
    if entries.len() == 1 && entries[0].path().is_dir() {
        Ok(entries[0].path())
    } else {
        Ok(dest.to_path_buf())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_platform_keys() {
        let (os, arch) = platform_keys();
        assert!(["windows", "linux", "mac"].contains(&os));
        assert!(["x64", "aarch64"].contains(&arch));
    }

    #[test]
    fn test_adoptium_response_deserialize() {
        let json = r#"{
            "binaries": [{
                "package": {
                    "name": "OpenJDK21U-jre_x64_linux_hotspot_21.0.5_11.tar.gz",
                    "link": "https://github.com/adoptium/temurin21-binaries/releases/download/x.tar.gz",
                    "sha256_checksum": "abc123",
                    "size": 50000000
                },
                "image_type": "jre",
                "architecture": "x64"
            }],
            "vendor": {"name": "Temurin"},
            "version_data": {"major": 21, "openjdk_version": "21.0.5+11", "semver": "21.0.5+11.0"}
        }"#;
        let parsed: AdoptiumResponse = serde_json::from_str(json).unwrap();
        assert!(parsed.binaries[0].package.name.ends_with(".tar.gz"));
        assert_eq!(parsed.version_data.major, 21);
        assert_eq!(parsed.vendor.name, "Temurin");
    }

    #[test]
    fn test_adoptium_asset_conversion() {
        // 模拟 adoptium_latest_jre 内的转换逻辑
        let name = "OpenJDK17U-jre_x64_windows_hotspot_17.0.13_11.zip";
        let format = if name.ends_with(".zip") { "zip" } else { "tar.gz" };
        assert_eq!(format, "zip");
    }
}
