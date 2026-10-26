//! Minecraft 服务器状态查询（SLP / Server List Ping）。
//!
//! 实现 1.7+ 现代协议：
//! Handshake (0x00) → Status Request (0x00) → 读取 JSON 响应 → Ping/Pong 测延迟。
//!
//! 借鉴 PCL.Core `Minecraft/ServerAddressResolver` 的职责划分：
//! 地址解析（含 SRV 记录）与状态查询分离。SRV 解析需要额外 DNS 库，
//! 当前版本仅支持直连 host:port（TODO 见模块尾部注释）。

use anyhow::{anyhow, bail, Result};
use serde::Deserialize;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// 服务器状态
#[derive(Debug, Clone, serde::Serialize)]
pub struct ServerStatus {
    /// 服务器地址 host:port
    pub address: String,
    /// MOTD（纯文本，已剥离颜色代码 §x）
    pub motd: String,
    /// 服务器版本名
    pub version_name: String,
    /// 协议版本号
    pub protocol: i64,
    /// 在线玩家数
    pub players_online: i64,
    /// 最大玩家数
    pub players_max: i64,
    /// 示例玩家名（最多 8 个，可能为空）
    pub sample_players: Vec<String>,
    /// 图标（PNG data: URI，可能为空）
    pub favicon: Option<String>,
    /// 往返延迟（毫秒）
    pub latency_ms: i64,
    /// mod/forge 信息（FML 网络标记时出现）
    pub modinfo: Option<ServerModInfo>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ServerModInfo {
    pub mod_type: String,
    pub mod_list: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct StatusResponse {
    #[serde(default)]
    version: Option<StatusVersion>,
    #[serde(default)]
    players: Option<StatusPlayers>,
    #[serde(default)]
    description: Option<serde_json::Value>,
    #[serde(default)]
    favicon: Option<String>,
    #[serde(default)]
    modinfo: Option<StatusModInfo>,
}

#[derive(Debug, Deserialize)]
struct StatusVersion {
    name: Option<String>,
    protocol: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct StatusPlayers {
    online: Option<i64>,
    max: Option<i64>,
    #[serde(default)]
    sample: Option<Vec<StatusSample>>,
}

#[derive(Debug, Deserialize)]
struct StatusSample {
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StatusModInfo {
    #[serde(rename = "type")]
    mod_type: Option<String>,
    #[serde(default)]
    mod_list: Option<Vec<serde_json::Value>>,
}

/// 查询服务器状态（1.7+ 现代协议）。
///
/// `timeout_ms`：连接与读取的总超时。
pub async fn ping_server(host: String, port: i32, timeout_ms: i64) -> Result<ServerStatus> {
    let timeout = Duration::from_millis(timeout_ms.clamp(500, 15000) as u64);
    let started = Instant::now();

    let addr = format!("{host}:{port}");
    let stream = TcpStream::connect(&addr).await.map_err(|e| {
        anyhow!(
            "无法连接 {addr}: {e}（请检查地址与端口，或服务器未开启）"
        )
    })?;
    let connect_latency = started.elapsed().as_millis() as i64;

    stream.set_nodelay(true).ok();
    let mut stream = stream;

    // ---- Handshake ----
    let host_bytes = host.as_bytes();
    let handshake_len = 1                       // packet id 0x00
        + varint_len(-1i64)                     // protocol version: -1 (unknown)
        + (varint_len(host_bytes.len() as i64) + host_bytes.len())
        + 2                                     // port
        + 1;                                    // next state = 1 (status)
    let mut handshake = Vec::with_capacity(handshake_len + 5);
    write_varint(&mut handshake, handshake_len as i64);
    write_varint(&mut handshake, 0x00);
    write_varint(&mut handshake, -1);
    write_varint(&mut handshake, host_bytes.len() as i64);
    handshake.extend_from_slice(host_bytes);
    handshake.extend_from_slice(&port.to_be_bytes());
    write_varint(&mut handshake, 1);
    write_all_timeout(&mut stream, &handshake, timeout).await?;

    // ---- Status Request ----
    let mut request = Vec::new();
    write_varint(&mut request, 1); // length: packet id only
    write_varint(&mut request, 0x00);
    write_all_timeout(&mut stream, &request, timeout).await?;

    // ---- Read response ----
    let packet = read_packet(&mut stream, timeout).await?;
    let mut reader = PacketReader::new(&packet);
    let packet_id = reader.read_varint()?;
    if packet_id != 0x00 {
        bail!("意外的响应包 id: 0x{packet_id:x}");
    }
    let json_len = reader.read_varint()? as usize;
    let json_bytes = reader.read_bytes(json_len)?;
    let text = String::from_utf8_lossy(json_bytes);
    let status: StatusResponse =
        serde_json::from_str(&text).map_err(|e| anyhow!("状态 JSON 解析失败: {e}"))?;

    // ---- Ping/Pong 测延迟 ----
    let mut ping_packet = Vec::new();
    write_varint(&mut ping_packet, 9); // length
    write_varint(&mut ping_packet, 0x01);
    ping_packet.extend_from_slice(&(started.elapsed().as_millis() as i64).to_be_bytes());
    let _ = write_all_timeout(&mut stream, &ping_packet, timeout).await;
    let mut latency_ms = connect_latency; // 至少用连接延迟
    // 尝试读取 pong 以获得更准确的延迟（失败不阻塞结果）
    if let Ok(pong) =
        tokio::time::timeout(Duration::from_millis(400), read_packet(&mut stream, timeout)).await
    {
        if let Some(p) = pong.ok().filter(|p| !p.is_empty()) {
            let mut r = PacketReader::new(&p);
            if let Ok(0x01) = r.read_varint() {
                let total = started.elapsed().as_millis() as i64;
                latency_ms = total.max(connect_latency).max(1);
            }
        }
    }
    drop(stream);

    // ---- 组装 ----
    let motd = status
        .description
        .map(parse_description)
        .unwrap_or_default();
    let (players_online, players_max, sample) = status
        .players
        .map(|p| {
            (
                p.online.unwrap_or(0),
                p.max.unwrap_or(0),
                p.sample
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|s| s.name.clone())
                    .take(8)
                    .collect::<Vec<_>>(),
            )
        })
        .unwrap_or((0, 0, Vec::new()));

    Ok(ServerStatus {
        address: addr,
        motd,
        version_name: status
            .version
            .as_ref()
            .and_then(|v| v.name.clone())
            .unwrap_or_default(),
        protocol: status.version.as_ref().and_then(|v| v.protocol).unwrap_or(0),
        players_online,
        players_max,
        sample_players: sample,
        favicon: status.favicon,
        latency_ms,
        modinfo: status.modinfo.map(|m| ServerModInfo {
            mod_type: m.mod_type.unwrap_or_default(),
            mod_list: m
                .mod_list
                .unwrap_or_default()
                .iter()
                .filter_map(|v| v.get("id").and_then(|x| x.as_str()).map(String::from))
                .collect(),
        }),
    })
}

// ---------------- 协议工具 ----------------

/// 写 varint（LEB128，最多 5 字节；负数按 u32 处理）
pub(crate) fn write_varint(buf: &mut Vec<u8>, value: i64) {
    let mut v = value as u32 as u64;
    loop {
        if v & !0x7F == 0 {
            buf.push(v as u8);
            return;
        }
        buf.push(((v & 0x7F) as u8) | 0x80);
        v >>= 7;
    }
}

fn varint_len(value: i64) -> usize {
    let mut buf = Vec::with_capacity(5);
    write_varint(&mut buf, value);
    buf.len()
}

async fn write_all_timeout(
    stream: &mut TcpStream,
    data: &[u8],
    timeout: Duration,
) -> Result<()> {
    tokio::time::timeout(timeout, stream.write_all(data)).await??;
    Ok(())
}

/// 读取一个完整数据包（varint 长度 + 内容）
async fn read_packet(stream: &mut TcpStream, timeout: Duration) -> Result<Vec<u8>> {
    async fn read_varint_stream(stream: &mut TcpStream) -> Result<i64> {
        let mut result: i64 = 0;
        let mut shift = 0u32;
        loop {
            let mut byte = [0u8; 1];
            let n = stream.read(&mut byte).await?;
            if n == 0 {
                bail!("连接被远端关闭");
            }
            result |= ((byte[0] & 0x7F) as i64) << shift;
            if byte[0] & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 35 {
                bail!("varint 过长（非法数据包）");
            }
        }
    }

    let fut = async {
        let len = read_varint_stream(stream).await?;
        if len <= 0 || len > 4 * 1024 * 1024 {
            bail!("非法包长度: {len}");
        }
        let mut buf = vec![0u8; len as usize];
        stream.read_exact(&mut buf).await?;
        Ok(buf)
    };
    tokio::time::timeout(timeout, fut).await?
}

/// 顺序读取器
struct PacketReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> PacketReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn read_varint(&mut self) -> Result<i64> {
        let mut result: i64 = 0;
        let mut shift = 0u32;
        loop {
            let byte = *self
                .data
                .get(self.pos)
                .ok_or_else(|| anyhow!("varint 越界"))?;
            self.pos += 1;
            result |= ((byte & 0x7F) as i64) << shift;
            if byte & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 35 {
                bail!("varint 过长");
            }
        }
    }

    fn read_bytes(&mut self, n: usize) -> Result<&[u8]> {
        if self.pos + n > self.data.len() {
            bail!("数据越界: 需要 {n} 字节, 剩余 {}", self.data.len() - self.pos);
        }
        let out = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(out)
    }
}

/// description 字段可能是纯字符串，也可能是组件 JSON（text/extra/color 等）
pub(crate) fn parse_description(value: serde_json::Value) -> String {
    fn strip_color(s: &str) -> String {
        // 剥离 § 颜色代码（§ + 1 字符）
        let mut out = String::with_capacity(s.len());
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c == '§' {
                chars.next(); // 跳过颜色码
                continue;
            }
            out.push(c);
        }
        out
    }

    fn visit(v: &serde_json::Value, out: &mut String) {
        match v {
            serde_json::Value::String(s) => out.push_str(s),
            serde_json::Value::Array(items) => {
                for item in items {
                    visit(item, out);
                }
            }
            serde_json::Value::Object(obj) => {
                if let Some(t) = obj.get("text").and_then(|t| t.as_str()) {
                    out.push_str(t);
                }
                if let Some(extra) = obj.get("extra") {
                    visit(extra, out);
                }
            }
            _ => {}
        }
    }

    let mut raw = String::new();
    visit(&value, &mut raw);
    strip_color(raw.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_varint_roundtrip() {
        let cases: Vec<i64> = vec![0, 1, 127, 128, 255, 256, 16383, 16384,
            65535, 2097151, 2097152, i32::MAX as i64, -1, -2147483648];
        for v in cases {
            let mut buf = Vec::new();
            write_varint(&mut buf, v);
            let mut reader = PacketReader::new(&buf);
            let decoded = reader.read_varint().unwrap();
            // varint 按 u32 位型编码（MC 协议签名语义由读取方解释），
            // 负数解码回 u32 位型对应的非负值
            assert_eq!(decoded, (v as u32) as i64, "roundtrip failed for {v}");
        }
    }

    #[test]
    fn test_varint_known_encoding() {
        // 协议已知样例：2097152 → 80 80 80 01
        let mut buf = Vec::new();
        write_varint(&mut buf, 2097152);
        assert_eq!(buf, vec![0x80, 0x80, 0x80, 0x01]);
        // 1 → 01
        let mut b2 = Vec::new();
        write_varint(&mut b2, 1);
        assert_eq!(b2, vec![0x01]);
    }

    #[test]
    fn test_parse_description_plain() {
        let v = serde_json::json!("A Minecraft Server");
        assert_eq!(parse_description(v), "A Minecraft Server");
    }

    #[test]
    fn test_parse_description_components() {
        let v = serde_json::json!({
            "text": "Hello ",
            "extra": [
                {"text": "World", "color": "red"},
                {"text": " §aGreen"}
            ]
        });
        assert_eq!(parse_description(v), "Hello World Green");
    }

    #[test]
    fn test_parse_description_nested_array() {
        let v = serde_json::json!([
            {"text": "Line1"}, "\n", {"text": "Line2"}
        ]);
        assert_eq!(parse_description(v), "Line1\nLine2");
    }

    #[test]
    fn test_status_response_deserialize() {
        let json = r#"{
            "version": {"name": "1.21.4", "protocol": 769},
            "players": {"max": 100, "online": 5, "sample": [{"name": "Steve"}]},
            "description": {"text": "§aWelcome§r"},
            "favicon": "data:image/png;base64,AAAA",
            "modinfo": {"type": "FML", "modList": [{"modid": "forge", "version": "1.0"}]}
        }"#;
        let status: StatusResponse = serde_json::from_str(json).unwrap();
        assert_eq!(status.version.as_ref().unwrap().protocol, Some(769));
        assert_eq!(status.players.as_ref().unwrap().online, Some(5));
        let motd = parse_description(status.description.unwrap());
        assert_eq!(motd, "Welcome");
        assert!(status.modinfo.is_some());
    }
}
