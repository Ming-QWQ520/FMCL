//! Java 运行时管理 API。

use crate::api::java::{find_java_candidates, probe_java, JavaInfo};

/// 探测并列出全部可用 Java 运行时（并行探测，按主版本升序）
pub async fn detect_javas(extra_dirs: Vec<String>) -> Result<Vec<JavaInfo>> {
    let candidates = find_java_candidates(extra_dirs);
    let mut handles = Vec::new();
    for c in candidates {
        handles.push(tokio::spawn(async move { probe_java(c).await.ok() }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(Some(info)) = h.await {
            out.push(info);
        }
    }
    out.sort_by(|a, b| a.major_version.cmp(&b.major_version).then(a.java_path.cmp(&b.java_path)));
    // 去重（同路径不同探测结果理论不会出现，防御性处理）
    out.dedup_by(|a, b| a.java_path == b.java_path);
    crate::log_info!("Java", "检测到 {} 个 Java 运行时", out.len());
    Ok(out)
}

/// 校验单个 Java 路径
pub async fn validate_java(java_path: String) -> Result<JavaInfo> {
    probe_java(java_path).await
}

/// 自动安装指定主版本 Java（Adoptium，进度走事件流）
pub async fn download_java(
    major: i32,
    session_id: String,
    sink: crate::frb_generated::StreamSink<crate::api::java_download::JavaInstallProgress>,
) -> Result<()> {
    let root = crate::core::paths::paths().java_dir.to_string_lossy().into_owned();
    crate::api::java_download::install_java(major, root, session_id, sink).await;
    Ok(())
}

/// 移除自动安装的 Java
pub fn remove_java(major: i32) -> Result<()> {
    let target = crate::core::paths::paths().java_dir.join(format!("java-{major}"));
    anyhow::ensure!(target.exists(), "未找到 Java {major} 的自动安装目录");
    std::fs::remove_dir_all(&target)?;
    crate::log_info!("Java", "已移除 Java {major}");
    Ok(())
}
