# FMCL TODO / 路线图

> FMCL（Fluent Minecraft Launcher）的开发路线图与平台适配清单。
> 打勾项为已完成，未打勾项按优先级排列。欢迎通过 Issue/PR 参与开发。

## 桌面端（Windows / Linux / macOS）

### 核心已完成 ✅

- [x] 多线程下载引擎（Rust 实现：并发、重试、SHA1 校验、实时速度）
- [x] 下载源切换（官方 / BMCLAPI）与自动回退
- [x] 原版版本安装（版本清单 / 客户端 jar / 库 / 资源 / log4j 配置）
- [x] 版本继承链解析（`inheritsFrom` 递归合并）
- [x] Fabric / Quilt 一键安装（官方 Meta API）
- [x] Forge / NeoForge 安装（1.13+ 现代处理器链 + 1.12- 旧版安装器）
- [x] Java 运行时扫描与智能选择（版本匹配 / 上向下兼容）
- [x] 完整启动参数构建（JVM 模板、classpath、natives、分辨率、quickPlay 占位）
- [x] 游戏进程管理（日志流、退出码、Rust 侧 GBK 解码）
- [x] 崩溃分析与修复建议（Java 版本 / 内存 / 模组 / 资源 / 驱动等常见模式）
- [x] 账户体系：离线（Mojang 离线 UUID 算法）/ 微软设备码 OAuth / Yggdrasil 外置登录
- [x] authlib-injector 自动下载与注入
- [x] Modrinth 模组搜索 / 版本解析 / 依赖树下载
- [x] 本地 Mod 管理（启用 / 停用 / 删除）
- [x] Riverpod 3 状态管理 + go_router 声明式路由
- [x] 浅色 / 深色主题
- [x] **整合包一键安装**：Modrinth `.mrpack` 解析 → 基础游戏/加载器复用安装 → 文件下载（SHA1 校验）→ overrides 释放（借鉴 PCL2 整合包体验，#D-01）
- [x] **版本隔离**：PCL2 式全局开关 + 每版本覆盖（隔离 / Java / 内存 / JVM 参数），libraries 与 assets 多版本共享（#D-03）
- [x] **版本设置**：每版本独立配置持久化到 `versions/<id>/fmcl-settings.json`（借鉴 PCL2「版本设置」）
- [x] **Java 自动安装**：Adoptium (Temurin) API 查询 + Rust 下载引擎 + SHA256 校验 + zip/tar.gz 解压托管（借鉴 PCL2 2.13 Java 管理，#D-11）
- [x] **服务器查询**：Rust 实现 SLP 协议（Handshake/Status/Ping，varint 分帧），MOTD 组件解析、图标、延迟、在线人数（#D-05）
- [x] **日志查看器**：游戏日志 / 崩溃报告汇总列表 + 全文搜索 + 行数统计（#D-12）
- [x] **设置持久化防抖**：状态立即生效、磁盘写入防抖 600ms（借鉴 PCL.Core 配置系统）
- [x] **多实例启动**：多会话并行运行、每实例独立日志与状态、会话级终止（#D-08）
- [x] **进程优先级**：高/普通/低，Rust 侧跨平台应用（Windows 优先级类别 / Unix nice，借鉴 HMCL，#D-16）
- [x] **服务器自动连接**：1.20+ 走 quickPlayMultiplayer，旧版追加 --server/--port（借鉴 PCL2/HMCL，#D-17）
- [x] **启动前命令**：自定义命令在游戏启动前执行，失败中止启动（借鉴 HMCL，#D-18）
- [x] **游戏环境变量与包装命令**：每行 KEY=VALUE 注入进程环境；wrapper 前缀（如 gamemoderun）（#D-19）
- [x] **启动前内存安全校验**：分配内存超过物理内存 90% 时拒绝启动（借鉴 PCL2，#D-20）
- [x] **CI 编译**：GitHub Actions 产出 Android APK（横屏）与 Windows 免安装包

### 计划中 🚧

- [ ] **D-01b CurseForge 整合包**：CurseForge `.zip` 导入（需要 CF API Key，见 #M-06）
- [ ] **D-02 自动更新**：检查 GitHub Release 更新并自升级
- [ ] **D-04 皮肤预览**：3D 皮肤查看器（账户页）
- [ ] **D-05b 服务器查询增强**：SRV 记录解析（需 DNS 库）/ Forge mod 列表展开展示
- [ ] **D-06 资源包 / 光影管理**：Modrinth resource pack / shader 安装
- [ ] **D-07 下载限速**：全局带宽限制设置
- [ ] **D-09 窗口置顶小部件**：游戏运行时悬浮内存监控
- [ ] **D-10 macOS 构建**：cargokit 已支持，补 CI 签名与公证
- [ ] **D-11b Java 版本范围选择**：按版本范围自动匹配（PCL2 2.13 完整行为）
- [ ] **D-12b 日志导出**：日志条目导出分享
- [ ] **D-13 Mod 更新检查**：本地 Mod 与 Modrinth 最新版本比对
- [ ] **D-14 国际化**：zh-CN 之外的 en-US 界面语言
- [ ] **D-15 Forge 处理器链并行化**：处理器 DAG 分析后并行执行

## Android 平台

> 目标：在移动端提供「浏览 / 下载 / 管理」完整体验 +「启动游戏」逐步解锁。
> 分阶段推进，编号与代码内 `TODO(ANDROID)` 注释对应。

- [ ] **A-01 启动游戏（核心难点）**
  - 方案：内置 JRE（aarch64 JRE8/17/21 构建，如 pojav 的 jamvm/openjdk 移植）
  - 需要进程派生（`Runtime.exec`）+ 重定向 stdin/stdout 到日志流
  - Rust 侧 `spawn_game_process` 已就绪，Android 端需替换进程层
  - 参考：PojavLauncher / Fold Craft Launcher 的 JRE 分发方案
- [ ] **A-02 Rust 动态库接入**
  - rust_builder 已包含 android cargokit 配置，补 `ndk` 工具链（`cargo ndk`）
  - `librust_lib_fmcl.so` 目标 abi：arm64-v8a / x86_64
- [ ] **A-03 下载引擎切换**：移除 Dart 降级路径，全量走 Rust 引擎
- [ ] **A-04 存储目录**：SAF 目录选择，游戏目录迁移工具（存储权限运行时申请已实现，#A-06）
- [ ] **A-05 Java 检测**：扫描内置 runtime 目录 / Termux 前缀
- [x] **A-06 权限申请流程**：清单声明 INTERNET / 存储 / 媒体权限，Android 11+ 引导「所有文件访问」授权页，Android 9- 运行时申请
- [ ] **A-07 移动端 UI 适配**：侧边栏 → 底部导航栏、窗口尺寸自适应
- [ ] **A-08 虚拟键鼠**：Pojav 式虚拟鼠标 / 触屏映射（长线目标）
- [ ] **A-09 电池与性能**：启动时唤醒锁、后台限制提示

## 已知限制 ⚠️

1. **Forge 1.20.2+ / NeoForge 1.20.2+** 新版安装器格式（非 install_profile 结构）暂未支持，
   安装器会给出明确错误提示。计划在 D-15 中统一实现。
2. **CurseForge API** 需要申请第三方 Key，暂未接入（Modrinth 已覆盖主要需求）。
3. **微软登录** 需要用户自备 Azure 应用 Client ID（见 README「微软登录配置」），
   项目不会内置共享凭据。
4. **离线账户** 无法进入开启在线验证的服务器。
5. Windows 命令行长度限制通过 `@argfile` 方案规避的计划（D-15 同期）。

## 参与开发

```bash
git clone https://github.com/Ming-QWQ520/FMCL.git
cd FMCL
flutter pub get
flutter_rust_bridge_codegen generate   # 需 Rust 1.96.0 + Flutter 3.47.5
flutter run -d windows                 # 或 linux
cargo test --manifest-path rust/Cargo.toml
flutter test
```

PR 请保持：`flutter analyze` 零错误、`cargo clippy` 零警告。
