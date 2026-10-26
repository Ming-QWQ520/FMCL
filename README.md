<div align="center">

# FMCL · Fluent Minecraft Launcher

**现代化 · 高效 · 生产级可用的 Minecraft 启动器**

Flutter 构建精美界面 · Rust 驱动高性能核心

[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.96.0-DEA584?logo=rust&logoColor=white)](https://rust-lang.org)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20Android-lightgrey)](https://github.com/Ming-QWQ520/FMCL)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Android Build](https://github.com/Ming-QWQ520/FMCL/actions/workflows/android.yml/badge.svg)](https://github.com/Ming-QWQ520/FMCL/actions/workflows/android.yml)
[![Windows Build](https://github.com/Ming-QWQ520/FMCL/actions/workflows/windows.yml/badge.svg)](https://github.com/Ming-QWQ520/FMCL/actions/workflows/windows.yml)

</div>

---

## 简介

FMCL（Fluent Minecraft Launcher）是一款从零重构的现代化 Minecraft 启动器。
界面层使用 **Flutter 3.47.5** 打造简洁高效的多风格 UI，核心层由 **Rust 1.96.0**
实现高性能的并发下载引擎、文件校验、归档解压与游戏进程管理，
两端通过 [flutter_rust_bridge 2](https://cjycode.com/flutter_rust_bridge/) 无缝集成。

设计上借鉴了 [PCL2](https://github.com/Meloong-Git/PCL)「简洁高效、用户友好」的理念
（感谢 [@Meloong-Git](https://github.com/Meloong-Git)），并融合现代桌面应用的多风格视觉语言。

## ✨ 功能特性

### 🎮 游戏管理
- **合并安装管线（Rust 实现，PCL2 式体验对齐）**：版本解析 → 客户端 / 库 / 资源下载 →
  加载器装配 → 版本 JSON 合并 → 补全扫描，一次调用完成全部装配
- **四款模组加载器**：
  - **Fabric** / **Quilt** —— Meta profile 直装
  - **Forge** —— 1.13+ 官方处理器链完整实现（data 解析 / token 替换 / 输出校验断点续装），1.12- 旧版安装器兼容
  - **NeoForge** —— 复用 Forgelike 现代管线
- **高清修复（OptiFine）**：与任意加载器组合时**按模组**放入 `mods`；
  纯原版时以 Tweaker 方式构造版本（免图形安装器，全自动无感安装）
- **版本继承链解析**：`inheritsFrom` 递归合并，正确处理 Forge/Fabric 版本定义
- **智能文件补全**：启动前校验库 / 资源 / natives 完整性，按需增量下载

### 🚀 启动体验
- **一键启动**：自动 Java 选择（版本精确匹配 → 向上兼容 → 手动指定），**缺失 Java 自动从 Adoptium 下载安装**（借鉴 PCL2 2.13 Java 管理）
- **崩溃诊断**（PCL2 式错误报告）：自动识别 Java 版本不匹配、内存不足、模组异常、
  显卡驱动等常见崩溃模式，并给出**可执行的一键修复建议**
- **实时日志**：启动页内嵌日志面板，错误 / 警告高亮
- **启动行为可配**：启动后隐藏 / 关闭启动器，全屏 / 分辨率自定义
- **服务器查询**：内置 SLP 协议 ping（Rust 实现），MOTD / 版本 / 在线人数 / 延迟一览
- **日志查看器**：游戏日志与崩溃报告汇总浏览、全文搜索（`设置 → 关于 → 日志查看器`）

### 👤 账户系统
- **离线账户**：与官方一致的离线 UUID 算法
- **微软账户**：标准 OAuth 设备码流程（Xbox Live XSTS → Minecraft Services）
- **Yggdrasil 外置登录**：兼容 authlib-injector 规范（LittleSkin 等），自动下载注入器
- **令牌自动续期**：微软 refresh token 与 Yggdrasil validate/refresh 全自动

### 📦 模组生态
- **Modrinth 集成**：搜索、版本过滤（加载器 + 游戏版本）、**依赖树自动解析下载**
- **本地 Mod 管理**：启用 / 停用（`.disabled` 后缀）/ 删除，自动读取 mod 元信息
- **整合包**：Modrinth `.mrpack` 解析安装（含依赖自动装配），支持窗口拖拽导入

### ⚙️ 下载引擎（Rust）
- 可配置并发（4~128 连接）、指数退避重试、SHA1 + 大小双重校验
- **多源候选**：每个条目自带官方 / BMCLAPI 回退链，逐个尝试直到成功
- 临时文件原子落盘，半成品永不污染
- 100ms 节流聚合进度事件，UI 流畅不卡顿
- **安装全链路下沉 Rust**：版本解析 / 处理器链 / JSON 合并 / 补全扫描，
  Flutter 仅负责界面与用户交互，保证 UI 流畅

### 🎨 界面设计
- **白底黑字主配色**：简洁克制的中性视觉，浅色 / 深色 / 跟随系统三态主题
- **自定义背景图**：任意图片设为启动器背景，不透明度 / 模糊可调
- **整合包拖拽导入**：把 `.mrpack` / `.zip` 拖进启动器窗口即可开始安装
- **多实例启动**：多个游戏实例同时运行，独立日志与崩溃诊断，可单独终止
- PCL2 式圆角卡片布局 + 自绘标题栏（Windows/Linux），侧边栏导航，状态保持的分支路由
- **版本隔离（PCL2 式）**：每个版本独立 `saves` / `options.txt` / `mods`，
  全局开关 + 每版本覆盖设置（隔离 / Java / 内存 / JVM 参数），
  libraries 与 assets 跨版本共享节省磁盘
- **整合包一键安装**：导入 Modrinth `.mrpack`，自动完成
  基础游戏 + 加载器安装 → 整合包文件下载（SHA1 校验）→ 配置释放
- **版本设置**：每版本独立配置持久化到 `versions/<id>/fmcl-settings.json`
- **设置持久化防抖**：高频修改不再频繁写盘（借鉴 PCL.Core 配置系统）

## 🏗️ 架构

```
FMCL/
├── lib/                        # Flutter (Dart)
│   ├── core/                   # 常量 / 路由 / 主题 / 日志 / 异常体系
│   ├── data/
│   │   ├── models/             # 版本 JSON / 清单 / 账户 / 设置 等模型
│   │   └── sources/            # 下载源抽象（官方 / BMCLAPI + 回退）
│   ├── services/
│   │   ├── download/           # 下载管理器（Rust 引擎封装 + Dart 降级）
│   │   ├── install/            # 原版 / Fabric / Quilt / Forge / NeoForge 安装器
│   │   ├── launch/             # 启动管线 / 参数构建 / 崩溃分析
│   │   ├── account/            # 微软 OAuth / Yggdrasil
│   │   ├── java/               # Java 检测与选择
│   │   ├── mod/                # Modrinth + 本地 Mod
│   │   └── version/            # 版本仓库 / 本地版本管理
│   ├── providers/              # Riverpod 3 状态层
│   ├── ui/                     # 按功能划分的页面（shell/home/download/…）
│   ├── rust_bridge/            # Rust 桥接统一入口（含平台降级）
│   └── src/rust/               # flutter_rust_bridge 生成代码
├── rust/                       # Rust 核心 (rust_lib_fmcl)
│   └── src/api/                # 下载引擎 / 哈希 / 归档 / Java / 进程 / 系统信息
├── rust_builder/               # cargokit 集成（桌面 & Android 构建）
├── android/                    # Android 平台（TODO + 桩实现，见 TODO.md）
├── windows/ linux/             # 桌面平台
└── test/                       # 单元测试
```

**状态管理**：Riverpod 3（Notifier / AsyncNotifier）
**路由**：go_router 16（StatefulShellRoute 分支保持状态）

## 🔨 从源码构建

### 环境要求

| 依赖 | 版本 |
|------|------|
| Flutter SDK | **3.47.5** |
| Dart SDK | 3.13.x（随 Flutter 附带） |
| Rust | **1.96.0**（见 `rust/rust-toolchain.toml`） |
| flutter_rust_bridge_codegen | 2.13.0 |
| Windows 构建 | Visual Studio 2022（含 C++ 桌面开发） |
| Linux 构建 | `cmake ninja libgtk-3-dev` |

### 步骤

```bash
# 1. 克隆
git clone https://github.com/Ming-QWQ520/FMCL.git
cd FMCL

# 2. 安装 FRB 代码生成器（或 cargo install flutter_rust_bridge_codegen --version 2.13.0）
npm i -g flutter_rust_bridge_codegen   # 或使用 GitHub Releases 预编译二进制

# 3. 生成 Rust↔Dart 绑定（如无 Rust 改动可跳过，绑定已提交）
flutter_rust_bridge_codegen generate

# 4. 运行
flutter pub get
flutter run -d windows    # 或 -d linux

# 5. 构建
flutter build windows     # Windows
flutter build linux       # Linux
flutter build apk         # Android（横屏预览版，含全部 ABI）
```

### CI 自动编译

推送至 `main` 后 GitHub Actions 自动构建（也可手动触发）：

| 工作流 | 产物 | 说明 |
|--------|------|------|
| `android.yml` | `FMCL-0.1.0-android.apk` | 通用 release APK，可直接安装体验 UI 与联网功能 |
| `windows.yml` | `FMCL-0.1.0-windows-x64.zip` | Windows 免安装压缩包，解压即用 |

产物位于 Actions 运行页的 Artifacts 区。

### 测试与质量

```bash
flutter analyze                                # 静态分析（0 错误 0 警告）
flutter test                                   # Dart 单元测试
cargo test --manifest-path rust/Cargo.toml     # Rust 单元测试
cargo clippy --manifest-path rust/Cargo.toml   # Rust lint（0 警告）
```

## 📱 Android 支持

Android 端目前为**横屏预览版**：界面可运行、联网功能（版本清单 / 下载 /
微软与外置登录 / 服务器查询）可用；游戏启动链路正在分阶段接入
（内置 JRE 分发、进程派生等）。

已就绪的平台能力：

- **横屏锁定**（sensorLandscape，跟随重力翻转）
- **权限**：INTERNET / 存储（Android 11+ 引导「所有文件访问」授权页，
  Android 9- 运行时申请）/ 媒体读取（Android 13+）
- **CI 编译**：推送后 Actions 自动产出通用 APK（见上文 CI 表格）

完整的 9 项 Android 适配路线图见 **[TODO.md](TODO.md)**（编号 A-01 ~ A-09），
代码中对应的 `TODO(ANDROID)` 注释标记了每一处桩实现的位置。

## ⚙️ 微软登录配置

FMCL 不内置共享的 Azure 凭据（安全考虑），使用微软登录需自备 Client ID：

1. 前往 [Azure Portal → 应用注册](https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade) → **新注册**
2. 受支持的账户类型：**个人 Microsoft 账户**
3. 重定向 URI：暂不需要（使用设备码流）
4. **身份验证 → 高级设置 → 启用「允许公共客户端流」** ← 必须
5. 复制 **应用程序(客户端) ID**，在 FMCL「设置 → 关于 → 微软登录配置」中粘贴

## 🙏 致谢

- **[PCL2 / Plain Craft Launcher](https://github.com/Meloong-Git/PCL)**（@Meloong-Git）—— 设计理念与交互灵感来源；MeloongCore 的架构思路给了本项目很大启发
- **[BMCLAPI](https://bmclapi2.bangbang93.com/)**（@bangbang93）—— 国内镜像加速
- **[Modrinth](https://modrinth.com)** / **FabricMC** / **QuiltMC** / **NeoForged** / **MinecraftForge** —— 开放的 API 与生态
- **[authlib-injector](https://github.com/yushijinhun/authlib-injector)**（@yushijinhun）—— 外置登录标准
- **[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/)** —— Flutter 与 Rust 的高效桥梁

## 📄 许可证

本项目基于 [GNU GPL-3.0-only](LICENSE) 协议开源。任何基于本项目的修改与分发版本都须以相同协议（GPL-3.0-only）开源，并保留原始版权声明。

Minecraft 是 Mojang Studios 的商标，本项目与 Mojang / Microsoft 无关联。本项目中的加载器图标、游戏相关素材等资源均归属 Minecraft 或对应加载器项目本身。

<div align="center">

**用 ♥ 与 Rust 构建** · [报告问题](https://github.com/Ming-QWQ520/FMCL/issues) · [路线图](TODO.md)

</div>
