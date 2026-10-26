//! Zip 归档操作：natives 解压、Jar 条目读取。
//!
//! 用 Rust 实现（而非 Dart archive 包）以获得：
//! - 显著更快的解压速度（数千个 natives/资源文件时尤其明显）
//! - 精确的条目级过滤（排除 META-INF 等）
//! - 符号链接/路径穿越攻击防护（zip-slip）

use anyhow::{Context, Result};
use std::fs::File;
use std::io::Read;
use std::path::{Component, Path};
use zip::ZipArchive;

/// 打开 zip/jar 归档
fn open_archive(path: &str) -> Result<ZipArchive<File>> {
    let file = File::open(path).with_context(|| format!("无法打开归档: {path}"))?;
    Ok(ZipArchive::new(file)?)
}

/// 防止 zip-slip：确保解压目标位于 dest 内部
fn safe_dest(dest: &Path, entry_name: &str) -> Result<std::path::PathBuf> {
    safe_join(dest, entry_name)
}

/// 安全拼接归档条目路径（crate 内部复用，含路径穿越防护）。
pub(crate) fn safe_join(dest: &Path, entry_name: &str) -> Result<std::path::PathBuf> {
    let mut result = dest.to_path_buf();
    for comp in Path::new(entry_name).components() {
        match comp {
            Component::Normal(part) => result.push(part),
            Component::CurDir => {}
            _ => anyhow::bail!("检测到非法 zip 条目路径: {entry_name}"),
        }
    }
    Ok(result)
}

/// 解压 natives 库（按版本 JSON 的 extract 规则过滤）。
///
/// - `exclude_prefixes`: 需要排除的条目前缀，如 ["META-INF/", ".git/"]
/// - `only_native_lib`: 为 true 时仅解压动态库文件（.dll/.so/.dylib/.jnilib）
///
/// 返回实际解压出的文件数。
pub fn extract_natives(
    jar_path: String,
    dest_dir: String,
    exclude_prefixes: Vec<String>,
    only_native_lib: bool,
) -> Result<i32> {
    let mut archive = open_archive(&jar_path)?;
    let dest = Path::new(&dest_dir);
    std::fs::create_dir_all(dest)?;

    let mut count = 0i32;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.name().to_string();

        // 排除规则
        if exclude_prefixes.iter().any(|p| name.starts_with(p.as_str())) {
            continue;
        }
        // 仅动态库模式
        if only_native_lib && !is_native_lib(&name) {
            continue;
        }
        if entry.is_dir() {
            continue;
        }

        let target = safe_dest(dest, &name)?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = File::create(&target)
            .with_context(|| format!("创建 natives 文件失败: {}", target.display()))?;
        std::io::copy(&mut entry, &mut out)?;
        count += 1;
    }
    Ok(count)
}

/// 读取 zip/jar 中单个条目的完整字节（用于解析 Forge 安装器内嵌 JSON 等）
pub fn read_zip_entry(jar_path: String, entry_name: String) -> Result<Vec<u8>> {
    let mut archive = open_archive(&jar_path)?;
    let mut entry = archive
        .by_name(&entry_name)
        .with_context(|| format!("归档中不存在条目: {entry_name}"))?;
    let mut buf = Vec::with_capacity(entry.size() as usize);
    entry.read_to_end(&mut buf)?;
    Ok(buf)
}

/// 列出 zip/jar 内全部条目名
pub fn list_zip_entries(jar_path: String) -> Result<Vec<String>> {
    let mut archive = open_archive(&jar_path)?;
    Ok((0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|e| e.name().to_string()))
        .collect())
}

/// 解压整个归档到目标目录（通用用途）
pub fn extract_all(zip_path: String, dest_dir: String) -> Result<i32> {
    let mut archive = open_archive(&zip_path)?;
    let dest = Path::new(&dest_dir);
    std::fs::create_dir_all(dest)?;
    let mut count = 0i32;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let target = safe_dest(dest, entry.name())?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = File::create(&target)?;
        std::io::copy(&mut entry, &mut out)?;
        count += 1;
    }
    Ok(count)
}

fn is_native_lib(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".dll")
        || lower.ends_with(".so")
        || lower.ends_with(".dylib")
        || lower.ends_with(".jnilib")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as IoWrite;

    #[test]
    fn test_extract_natives_filter() {
        let dir = std::env::temp_dir().join("fmcl_test_zip");
        let zip_path = dir.join("test.jar");
        std::fs::create_dir_all(&dir).unwrap();

        // 构造测试 jar：含 META-INF（应排除）与 test.dll、libtest.so
        let file = File::create(&zip_path).unwrap();
        let mut zw = zip::ZipWriter::new(file);
        let opts: zip::write::SimpleFileOptions = Default::default();
        zw.start_file("META-INF/MANIFEST.MF", opts).unwrap();
        zw.write_all(b"manifest").unwrap();
        zw.start_file("test.dll", opts).unwrap();
        zw.write_all(b"dll-bytes").unwrap();
        zw.start_file("libtest.so", opts).unwrap();
        zw.write_all(b"so-bytes").unwrap();
        zw.finish().unwrap();

        let dest = dir.join("natives");
        let count = extract_natives(
            zip_path.to_string_lossy().into_owned(),
            dest.to_string_lossy().into_owned(),
            vec!["META-INF/".into()],
            false,
        )
        .unwrap();
        assert_eq!(count, 2);
        assert!(dest.join("test.dll").exists());
        assert!(dest.join("libtest.so").exists());
        assert!(!dest.join("META-INF").exists());

        // only_native_lib 模式
        let dest2 = dir.join("natives2");
        let count2 = extract_natives(
            zip_path.to_string_lossy().into_owned(),
            dest2.to_string_lossy().into_owned(),
            vec!["META-INF/".into()],
            true,
        )
        .unwrap();
        assert_eq!(count2, 2);
    }
}
