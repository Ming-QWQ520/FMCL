//! 文件哈希计算（SHA1 / MD5 / SHA256）。
//!
//! 采用分块读取，避免大文件（客户端 jar 数百 MB）占满内存。

use anyhow::{Context, Result};
use md5::Md5;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{BufReader, Read};

const BUF_SIZE: usize = 1024 * 1024; // 1 MiB

fn hash_file<D: Digest>(path: &str, mut digest: D) -> Result<String> {
    let file = File::open(path).with_context(|| format!("无法打开文件进行哈希: {path}"))?;
    let mut reader = BufReader::with_capacity(BUF_SIZE, file);
    let mut buf = vec![0u8; BUF_SIZE];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        digest.update(&buf[..n]);
    }
    Ok(hex::encode(digest.finalize()))
}

/// 计算文件 SHA1（Mojang 官方资源校验算法）
pub fn file_sha1(path: String) -> Result<String> {
    hash_file(&path, Sha1::new())
}

/// 计算文件 MD5
pub fn file_md5(path: String) -> Result<String> {
    hash_file(&path, Md5::new())
}

/// 计算文件 SHA256
pub fn file_sha256(path: String) -> Result<String> {
    hash_file(&path, Sha256::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_sha1_known_vector() {
        let dir = std::env::temp_dir().join("fmcl_test_hash");
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a.txt");
        let mut fh = File::create(&f).unwrap();
        fh.write_all(b"hello world").unwrap();
        drop(fh);
        // echo -n "hello world" | sha1sum
        let sha = file_sha1(f.to_string_lossy().into_owned()).unwrap();
        assert_eq!(sha, "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed");
    }

    #[test]
    fn test_md5_known_vector() {
        let dir = std::env::temp_dir().join("fmcl_test_hash");
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("b.txt");
        std::fs::write(&f, b"hello world").unwrap();
        let md5 = file_md5(f.to_string_lossy().into_owned()).unwrap();
        assert_eq!(md5, "5eb63bbbe01eeed093cb22bb8f5acdc3");
    }
}
