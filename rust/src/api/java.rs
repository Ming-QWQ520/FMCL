//! Java 运行时检测。
//!
//! 扫描常见安装目录 + 环境变量 + 用户自定义目录，
//! 对每个候选项执行 `java -version` 解析真实主版本号。

use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::process::Command;
use walkdir::WalkDir;

/// 一个检测到的 Java 运行时
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct JavaInfo {
    /// java 可执行文件绝对路径
    pub java_path: String,
    /// Java 主版本号（8, 17, 21 ...）
    pub major_version: i32,
    /// 完整版本字符串
    pub version_string: String,
    /// 供应方（如 Adoptium / Oracle / GraalVM）
    pub vendor: String,
    /// 是否 64 位
    pub is_64bit: bool,
    /// 是否为 JRE-only（无 javac）
    pub is_jre: bool,
}

/// 扫描候选 Java 安装根目录（不含探测，只收集 bin/java 所在目录）。
///
/// `extra_dirs`: 用户在设置中添加的额外搜索目录（递归扫描）。
pub fn find_java_candidates(extra_dirs: Vec<String>) -> Vec<String> {
    let mut roots: Vec<PathBuf> = Vec::new();

    // 环境变量
    if let Ok(jh) = std::env::var("JAVA_HOME") {
        roots.push(PathBuf::from(jh));
    }

    match std::env::consts::OS {
        "windows" => {
            for pf in [
                std::env::var("ProgramFiles").unwrap_or_else(|_| "C:\\Program Files".into()),
                std::env::var("ProgramFiles(x86)")
                    .unwrap_or_else(|_| "C:\\Program Files (x86)".into()),
                std::env::var("LOCALAPPDATA").unwrap_or_else(|_| String::new()),
            ]
            .into_iter()
            .filter(|s| !s.is_empty())
            {
                let pf = PathBuf::from(pf);
                for sub in ["Java", "Eclipse Adoptium", "AdoptOpenJDK", "Zulu", "Amazon Corretto", "Microsoft", "BellSoft", "Programs"] {
                    roots.push(pf.join(sub));
                }
                // IDEA/Android Studio 下载的 JDK
                if let Ok(home) = std::env::var("USERPROFILE") {
                    roots.push(PathBuf::from(home).join(".jdks"));
                }
            }
            // 启动器自带运行时
            if let Some(exe_dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(|p| p.to_path_buf())) {
                roots.push(exe_dir.join("runtime"));
                roots.push(exe_dir.join("java"));
            }
        }
        "linux" | "android" => {
            for p in ["/usr/lib/jvm", "/opt/java", "/usr/java", "/opt/jdk"] {
                roots.push(PathBuf::from(p));
            }
            if let Ok(home) = std::env::var("HOME") {
                roots.push(PathBuf::from(&home).join(".jdks"));
                roots.push(PathBuf::from(&home).join(".sdkman/candidates/java"));
            }
            if let Some(exe_dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(|p| p.to_path_buf())) {
                roots.push(exe_dir.join("runtime"));
            }
        }
        "macos" => {
            roots.push(PathBuf::from("/Library/Java/JavaVirtualMachines"));
            if let Ok(home) = std::env::var("HOME") {
                roots.push(PathBuf::from(home).join(".jdks"));
            }
        }
        _ => {}
    }

    // 用户自定义目录
    for d in extra_dirs {
        roots.push(PathBuf::from(d));
    }

    // 遍历查找 java 可执行文件（深度限制 4，避免扫盘过久）
    let java_exe_name = if std::env::consts::OS == "windows" { "java.exe" } else { "java" };
    let mut found: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for root in roots {
        if !root.exists() {
            continue;
        }
        for entry in WalkDir::new(&root)
            .max_depth(4)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            let p = entry.path();
            if p.is_file() && p.file_name().map(|n| n == java_exe_name).unwrap_or(false) {
                let canonical = p.to_string_lossy().into_owned();
                if seen.insert(canonical.clone()) {
                    found.push(canonical);
                }
            }
        }
    }
    found.sort();
    found
}

/// 探测单个 java 可执行文件：运行 `java -version` 并解析版本信息。
pub async fn probe_java(java_path: String) -> Result<JavaInfo> {
    let output = Command::new(&java_path)
        .arg("-version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| anyhow!("执行 {java_path} -version 失败: {e}"))?;

    // 注意：java -version 输出到 stderr
    let text = String::from_utf8_lossy(&output.stderr).into_owned();
    parse_java_version_output(&java_path, &text)
}

/// 从 `java -version` 的输出解析版本信息
pub fn parse_java_version_output(java_path: &str, text: &str) -> Result<JavaInfo> {
    let first_line = text.lines().next().unwrap_or_default();
    // 例如: openjdk version "21.0.1" 2023-10-17
    //       java version "1.8.0_391"
    let version_string = first_line
        .split('"')
        .nth(1)
        .ok_or_else(|| anyhow!("无法从输出解析版本号: {first_line}"))?
        .to_string();

    let major = parse_major(&version_string)?;

    let vendor = detect_vendor(&text.to_ascii_lowercase(), &java_path.to_ascii_lowercase());
    let is_64bit = !text.to_ascii_lowercase().contains("32-bit");
    let java_home = Path::new(java_path).parent().unwrap_or(Path::new("/"));
    let is_jre = !java_home.join(if cfg!(windows) { "javac.exe" } else { "javac" }).exists();

    Ok(JavaInfo {
        java_path: java_path.to_string(),
        major_version: major,
        version_string,
        vendor,
        is_64bit,
        is_jre,
    })
}

/// 解析主版本号：21.0.1 → 21；1.8.0_391 → 8
fn parse_major(version: &str) -> Result<i32> {
    let parts: Vec<&str> = version.split('.').collect();
    if parts.len() >= 2 && parts[0] == "1" {
        // 旧版本格式 1.8.0_xx
        parts[1]
            .parse::<i32>()
            .map_err(|_| anyhow!("无法解析旧式版本号: {version}"))
    } else {
        parts[0]
            .split(|c: char| !c.is_ascii_digit())
            .next()
            .unwrap_or_default()
            .parse::<i32>()
            .map_err(|_| anyhow!("无法解析版本号: {version}"))
    }
}

fn detect_vendor(lower_text: &str, lower_path: &str) -> String {
    let table: &[(&str, &str)] = &[
        ("adoptium", "Eclipse Adoptium"),
        ("temurin", "Eclipse Temurin"),
        ("adoptopenjdk", "AdoptOpenJDK"),
        ("zulu", "Azul Zulu"),
        ("corretto", "Amazon Corretto"),
        ("graal", "GraalVM"),
        ("microsoft", "Microsoft OpenJDK"),
        ("bellsoft", "BellSoft Liberica"),
        ("java(tm) se", "Oracle"),
        ("oracle", "Oracle"),
        ("openjdk", "OpenJDK"),
        ("hotspot", "HotSpot"),
        ("ibm", "IBM"),
        ("dragonwell", "Alibaba Dragonwell"),
        ("bi-sheng", "Bisheng"),
    ];
    for (key, name) in table {
        if lower_text.contains(key) || lower_path.contains(key) {
            return name.to_string();
        }
    }
    "未知供应商".into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_modern_version() {
        let out = r#"openjdk version "21.0.1" 2023-10-17
OpenJDK Runtime Environment Temurin-21.0.1+12 (build 21.0.1+12-mixed)
OpenJDK 64-Bit Server VM Temurin-21.0.1+12 (build 21.0.1+12-mixed, sharing)"#;
        let info = parse_java_version_output("/usr/bin/java", out).unwrap();
        assert_eq!(info.major_version, 21);
        assert_eq!(info.version_string, "21.0.1");
        assert_eq!(info.vendor, "Eclipse Temurin");
        assert!(info.is_64bit);
    }

    #[test]
    fn test_parse_legacy_version() {
        let out = r#"java version "1.8.0_391"
Java(TM) SE Runtime Environment (build 1.8.0_391-b12)
Java HotSpot(TM) 64-Bit Server VM (build 25.391-b12, mixed mode)"#;
        let info = parse_java_version_output("C:\\java.exe", out).unwrap();
        assert_eq!(info.major_version, 8);
        assert_eq!(info.vendor, "Oracle");
    }
}
