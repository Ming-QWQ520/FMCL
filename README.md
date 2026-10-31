<div align="center">

# FMCL · Fluent Minecraft Launcher

**现代化 · 高效 · 生产级可用的 Minecraft 启动器**

Flutter 构建精美界面 · Rust 驱动全部核心逻辑

[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.96.0-DEA584?logo=rust&logoColor=white)](https://rust-lang.org)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)](https://github.com/Ming-QWQ520/FMCL)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Windows Build](https://github.com/Ming-QWQ520/FMCL/actions/workflows/windows.yml/badge.svg)](https://github.com/Ming-QWQ520/FMCL/actions/workflows/windows.yml)

</div>

---

## 简介

FMCL（Fluent Minecraft Launcher）是一款彻底重构的现代化 Minecraft 启动器，
**全部业务逻辑运行在 Rust 核心**（版本安装、文件补全、游戏启动、下载引擎、
账户认证、设置与日志持久化），Flutter 层只负责界面渲染与桥接通信，
两端通过**手写 C-ABI JSON 桥**（`fmcl_call` 单一分发入口 + 事件回调，
无需任何代码生成）无缝集成。

UI 与交互全面对齐 [PCL2](https://github.com/Meloong-Git/PCL)
（感谢 [@Meloong-Git](https://github.com/Meloong-Git)）：
合并安装、版本隔离、便携目录、自绘标题栏、崩溃诊断。

## ✨ 功能特性

### 🎮 游戏管理
- **合并安装管线（Rust 实现，PCL2 式体验对齐）**：版本解析 → 客户端 / 库 / 资源下载 →
  加载器装配 → 版本 JSON 合并 → 补全扫描，一次调用完成全部装配
- **四款模组加载器**：
  - **Fabric** / **Quilt** —— Meta profile 直装
  - **Forge** —— 1.13+ 官方处理器链完整实现（data 解析 / token 替换 /
    输出校验断点续装），1.12- 旧版安装器兼容
  - **NeoForge** —— 复用 Forgelike 现代管线
- **高清修复（OptiFine）**：与任意加载器组合时**按模组**放入 `mods`；
  纯原版时以 Tweaker 方式构造版本（免图形安装器，全自动无感安装）
- **版本继承链解析**：`inheritsFrom` 递归合并，正确处理 Forge/Fabric 版本定义
- **智能文件补全**：启动前校验库 / 资源 / natives 完整性，按需增量下载
- **外部版本导入**：PCL2 式导入任意现成版本目录，导入后自动补全

### 🚀 启动体验
- **一键启动**：自动 Java 选择（版本精确匹配 → 向上兼容 → 手动指定），
  **缺失 Java 自动从 Adoptium 下载安装**
- **崩溃诊断**（PCL2 式错误报告）：自动识别 Java 版本不匹配、内存不足、模组异常、
  显卡驱动等常见崩溃模式，并给出可执行的修复建议
- **实时日志**：启动页内嵌日志面板，错误 / 警告高亮；完整日志落盘至
  `exe 所在目录\FMCL\logs\`（latest.log + 按天归档 + 轮转）
- **启动行为可配**：启动后隐藏 / 关闭启动器，全屏 / 分辨率自定义
- **多实例启动**：多个游戏实例同时运行，独立日志与崩溃诊断，可单独终止
- **版本隔离（PCL2 式）**：每版本独立 `saves` / `options.txt` / `mods`，
  全局开关 + 每版本覆盖设置，libraries 与 assets 跨版本共享节省磁盘

### 👤 账户系统
- **离线账户**：与官方一致的离线 UUID 算法
- **微软账户**：标准 OAuth 设备码流程（Xbox Live XSTS → Minecraft Services），
  使用开源启动器通用公开客户端，开箱即用
- **Yggdrasil 外置登录**：兼容 authlib-injector 规范（LittleSkin 等）；
  注入器自动下载至 `exe 所在目录\FMCL\lib\authlib-injector\authlib-injector.jar`
- **令牌自动续期**：微软 refresh token 与 Yggdrasil validate/refresh 全自动

### 📦 模组生态
- **Modrinth 集成**：模组 / 资源包 / 光影 / 数据包搜索、
  版本过滤（加载器 + 游戏版本）、一键安装到版本隔离感知目录
- **整合包**：Modrinth `.mrpack` 与 CurseForge 整合包解析安装
  （含基础游戏与加载器自动装配），支持窗口拖拽导入

### ⚙️ 下载引擎（Rust）
- 可配置并发（4~128 连接）、指数退避重试、SHA1 + 大小双重校验
- **多源候选**：每个条目自带官方 / BMCLAPI 回退链，逐个尝试直到成功
- 临时文件原子落盘，半成品永不污染
- 100ms 节流聚合进度事件，UI 流畅不卡顿
- **安装全链路下沉 Rust**：版本解析 / 处理器链 / JSON 合并 / 补全扫描，
  Flutter 仅负责界面渲染与通信

### 🎨 界面设计
- **白底黑字主配色**：简洁克制的中性视觉，浅色 / 深色 / 跟随系统三态主题
- **自定义背景图**：任意图片设为启动器背景，不透明度 / 模糊可调
- **自绘标题栏**（Windows）：无系统边框，窗口按钮全高热区、
  120ms 平滑 Hover 过渡、关闭键系统红
- PCL2 式圆角卡片布局 + 侧边栏导航，状态保持的分支路由
- **版本设置**：每版本独立配置持久化到 `versions/<id>/fmcl-settings.json`

## 🏗️ 架构

```
FMCL/
├── lib/                        # Flutter（仅渲染与通信）
│   ├── rust_bridge/            # C-ABI JSON 桥（FFI 底层 + 类型化 API）
│   ├── state/                  # Riverpod 状态层（Rust 数据镜像）
│   └── ui/                     # 页面 / 外壳 / 主题 / 通用组件
├── rust/                       # Rust 核心 (rust_lib_fmcl)
│   └── src/
│       ├── bridge.rs           # C-ABI 入口（fmcl_call / 事件回调）
│       ├── dispatch.rs         # 方法分发表（约 50 个业务方法）
│       ├── core/               # 目录解析 / 日志 / 设置 / 账户存储
│       ├── api/                # 安装 / 补全 / 启动 / 清单 / 内容 / 认证 / Java / 进程
│       └── util/               # HTTP 下载引擎 / 取消注册表
├── rust_builder/               # cargokit 集成（Windows / Linux 构建）
├── windows/ linux/             # 桌面平台
└── .github/workflows/          # CI（Windows 构建产物：免安装 zip）
```

**通信模型**：Dart 调用 `fmcl_call(method, json)` → Rust 在 tokio 运行时执行 →
过程事件与最终结果经单一事件回调回传（`NativeCallable.listener` 自动跨线程投递）。
普通方法映射为 `Future<T>`，流式方法（安装 / 启动 / 补全 / 登录）映射为 `Stream<T>`。

**状态管理**：Riverpod 3 · **路由**：go_router（StatefulShellRoute 分支保持状态）

## 🔨 从源码构建

### 环境要求

| 依赖 | 版本 |
|------|------|
| Flutter SDK | **3.47.5** |
| Dart SDK | 3.13.x（随 Flutter 附带） |
| Rust | **1.96.0**（见 `rust/rust-toolchain.toml`） |
| Windows 构建 | Visual Studio 2022（含 C++ 桌面开发） |
| Linux 构建 | `cmake ninja libgtk-3-dev` |

### 步骤

```bash
# 1. 克隆
git clone https://github.com/Ming-QWQ520/FMCL.git
cd FMCL

# 2. 运行（无需任何代码生成步骤）
flutter pub get
flutter run -d windows    # 或 -d linux

# 3. 构建
flutter build windows     # Windows
flutter build linux       # Linux
```

### CI 自动编译

Windows 工作流支持手动触发（workflow_dispatch）：

| 工作流 | 产物 | 说明 |
|--------|------|------|
| `windows.yml` | `FMCL-0.1.0-windows-x64.zip` | Windows 免安装压缩包，解压即用 |

产物位于 Actions 运行页的 Artifacts 区。

### 测试与质量

```bash
flutter analyze                                # Dart 静态分析
cargo check --manifest-path rust/Cargo.toml    # Rust 编译检查
```

## ⚙️ 便携目录布局

```
<exe 所在目录>/
├── FMCL/
│   ├── logs/                        启动器完整日志（latest.log + 轮转 + 游戏镜像）
│   ├── lib/authlib-injector/        外置登录注入器
│   ├── cache/                       版本清单缓存
│   ├── java/                        自动安装的 Java 运行时
│   ├── config.json                  全局设置
│   └── accounts.json                账户存储
└── .minecraft/                      游戏目录（便携默认）
```

## 🙏 致谢

- **[PCL2 / Plain Craft Launcher](https://github.com/Meloong-Git/PCL)**（@Meloong-Git）—— 设计理念与交互灵感来源
- **[BMCLAPI](https://bmclapi2.bangbang93.com/)**（@bangbang93）—— 国内镜像加速
- **[Modrinth](https://modrinth.com)** / **FabricMC** / **QuiltMC** / **NeoForged** / **MinecraftForge** —— 开放的 API 与生态
- **[authlib-injector](https://github.com/yushijinhun/authlib-injector)**（@yushijinhun）—— 外置登录标准

## 📄 许可证

本项目基于 [GNU GPL-3.0-only](LICENSE) 协议开源。任何基于本项目的修改与分发版本都须以相同协议（GPL-3.0-only）开源，并保留原始版权声明。

Minecraft 是 Mojang Studios 的商标，本项目与 Mojang / Microsoft 无关联。本项目中的加载器图标、游戏相关素材等资源均归属 Minecraft 或对应加载器项目本身。

<div align="center">

**用 ♥ 与 Rust 构建** · [报告问题](https://github.com/Ming-QWQ520/FMCL/issues)

</div>
