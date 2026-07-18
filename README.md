# HermesSync 一键同步工具

> 两台 Windows 设备之间，像 CherryStudio 一样「一键存 / 一键取」地同步 **Hermes Agent** 数据的图形化工具。

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2B-blue.svg)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-informational.svg)](https://docs.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-v1.0--fixed-success.svg)](CHANGELOG.md)

---

## ✨ 这是什么

你在**两台 Windows 设备**上都在用 Hermes Agent，希望像 CherryStudio 那样——**双击打开、点一下就备份、再点一下就恢复**，而不是去手动跑 `hermes-sync-out.ps1` / `hermes-sync-in.ps1` 一堆脚本。

HermesSync 就是为此而生的一个**单文件、双击即用**的图形界面工具：

- **「存」**：把本机 Hermes 数据打包备份到同步目录（百度网盘文件夹 / U 盘）。
- **「取」**：从同步目录把备份恢复覆盖回本机。

全程中文界面、带进度条和实时日志，备份前后自动做快照与完整性校验。

---

## 🚀 核心特性

| 特性 | 说明 |
| --- | --- |
| 🖥️ 图形界面 | Windows Forms 原生 GUI，深色主题，双击 `.ps1` 即用，无需安装 |
| 💾 一键备份（存） | 扫描 → 压缩 → 校验 → 复制到同步目录 → 自动清理旧备份 |
| ♻️ 一键恢复（取） | 查找最新 → 回滚快照 → 解压 → **镜像覆盖** → 验证 |
| 🔒 回滚机制 | 恢复前自动快照，失败自动回滚，支持撤销操作 |
| ✅ 完整性校验 | 备份 ZIP 读取条目数校验，避免残缺备份被恢复 |
| 🧹 智能清理 | 自动保留最近 N 个备份，超出则删除最旧 |
| 🛑 优雅进程管理 | Hermes 运行时也能备份：WM_CLOSE 优雅关闭 → 按 PID 强杀 → 失败提示手动关闭（不再闪退、不再误杀自身）|
| 🧰 一键启动器 | `启动HermesSync.bat`，零改动原脚本、无杀软误报、可整包拷贝分发 |
| 🌏 全中文化 | 界面、日志、提示全部中文，对齐 CherryStudio 体验目标 |

---

## 🏗️ 工作原理

```
┌─────────────────────────────────────────────┐
│              HermesSyncGUI.ps1              │
├─────────────────────────────────────────────┤
│  [GUI]      Windows Forms (PowerShell 5.1)  │
│  [备份]     扫描 → 压缩 → 校验 → 复制 → 清理  │
│  [恢复]     查找 → 快照 → 解压 → 覆盖 → 验证  │
├─────────────────────────────────────────────┤
│  [进程管理]  检测 Hermes → 终止 → 外部杀手    │
├─────────────────────────────────────────────┤
│  [存储层]                                 │
│   · config.json           用户配置          │
│   · syncDir/*.zip         同步副本（主备份）│
│   · Backups/*.zip         本地备份副本      │
│   · Backups/.rollback/    回滚快照          │
│   · sync.log              操作日志          │
└─────────────────────────────────────────────┘
```

### 备份流程（存）

1. 检测 Hermes 进程 → 弹窗「是否强制终止」→ 用户确认
2. 检测同步目录写入权限
3. 扫描 `HermesDataDir` + `WorkspaceDir`（排除 `logs` / `.git` / `.log` / `.tmp` / `tmp*`）
4. 复制到临时目录 → 构建 `HermesSync_YYYYMMDD_HHMMSS.zip`
5. ZIP 完整性校验（读取条目数）
6. 复制到 `syncDir`
7. 自动清理旧备份（超过 `localBackupLimit` 则删最旧）

### 恢复流程（取）

1. 检测 Hermes 进程 → 弹窗确认终止
2. 查找最新备份 ZIP
3. 冲突检测（本机数据 vs 备份时间戳）
4. 创建回滚快照
5. 校验目标路径可写
6. 解压 ZIP → **镜像覆盖**（`Remove-Item` 先清空目标再复制，本地新增被清理、备份内容完整保留）
7. 关键文件验证（`state.db`、`config.yaml` 存在性）
8. 成功则清理快照 / 失败则自动回滚

---

## 📦 安装与运行

### 环境要求

- Windows 10 / 11（64 位）
- PowerShell 5.1（系统内置，无需安装）
- .NET Framework（系统自带）
- 以**普通用户**双击运行即可；若同步目录在受保护路径，建议右键「以管理员身份运行」

### 快速开始

```text
1. 把整个工具目录拷贝到任意位置（如 E:\Documents\Hermes\HermesSync_修复版\）
2. 双击 启动HermesSync.bat
3. 首次运行弹出配置向导，填写：
     - hermesDataDir : Hermes 数据目录（如 D:\Program Files\Hermes Agent CN Desktop\data\hermes-home）
     - workspaceDir  : 工作空间目录
     - syncDir       : 同步目录（百度网盘文件夹 / U 盘，建议填真实路径）
     - localBackupLimit : 本地保留备份数（默认 5）
4. 点击「存」备份本机，换到另一台设备点击「取」恢复。
```

> ⚠️ **重要**：`syncDir` 必须指向两台设备共享的同步目录（百度网盘同步文件夹、U 盘等）。
> 若留空，首次运行会有引导提示但无法完成备份。

### 桌面快捷方式（可选）

创建 `Hermes一键同步.lnk`，目标：

```text
C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File "工具目录\HermesSyncGUI.ps1"
```

---

## 🧪 测试与质量

本轮（v1.0-fixed）的验证结果（来自开发复盘）如下：

| 测试文件 | 验证点 | 结果 |
| --- | --- | --- |
| `regression_test.ps1` | 作用域 / 配置 / 目录守卫 / 计时（T0–T11） | ✅ 12/12 PASS |
| `qa_restore_contract.ps1` | 备份结构 / 恢复映射 / 镜像语义 / 旧格式拒绝 | ✅ 4/4 PASS |
| `restore_e2e_test.ps1` | 恢复端到端契约闭环 | ✅ 4/4 PASS |
| `mirror_restore_test.ps1` | 本地新增被清、备份内容保留 | ✅ PASS |
| `qa_nullkey_indep.ps1` | 真实执行无 Null-key、Relative 正确 | ✅ PASS |
| `Parser.ParseFile` | 主脚本语法 | ✅ 0 错误 |

> 验证方法论升级：采用「写文件 → Read 回读」的真实执行法，而非仅语法解析或逻辑复刻，
> 能抓出纯语法解析完全无感的运行时错误（如哈希字面量内赋值导致的 Null-key 异常）。

> 仓库内置测试套件：`Test-Core.ps1`、`Test-Integration.ps1`、`Test-StopProcess.ps1`（详见上方「项目结构」）。

---

## 📌 当前状态（v1.0-fixed）

工具已从交接文档标注的「开发暂停（运行阻塞）」状态，经 **8 轮修复 + 1 个一键启动器**
推进到**可用状态**：

- ✅ Hermes 运行时可正常备份（F5 阻塞已解决）
- ✅ 恢复真正生效（修复了最底层的「备份/恢复目录契约不一致」导致的静默空操作）
- ✅ 界面全中文化、一键启动、原始基线受保护（可随时 diff / 回退）

### 已知限制与后续规划

| 优先级 | 项 | 说明 |
| --- | --- | --- |
| P1 | `workspaceDir` 范围收敛 | 当前备份体积偏大（最新 ~142MB），且镜像恢复可能误删本地新增，需只备份用户真正关心的子目录 |
| P1 | 旧备份迁移引导 | 备份格式变更后，旧版拍平结构备份无法恢复，已有「格式不兼容」提示，可加「一键用新工具重新存」 |
| P2 | 安装 / 卸载集成（F9） | 右键菜单、注册表，便于分发 |
| P2 | 增量备份 | 减少体积与时间 |
| P3 | 计划任务自动备份 | 定时同步 |
| P3 | 多设备冲突检测 | 双设备避免互相覆盖 |

---

## 🔧 开发复盘（得与失）

> 本工具由一份「开发报告（得与失复盘）」沉淀而来，这里保留最值得记住的两条经验。

**得 ——**

- 最深层的缺陷被定位：恢复「覆盖无效」表象曾被误判为「合并 vs 镜像」，
  真因是**备份把源拍平进 ZIP 根、恢复却按文件夹名匹配 → 分支永远不可达**。
  用「最小改动」（备份加源名层 + 恢复旧格式拒绝）彻底修复。
- 验证方法论升级：从「逻辑复刻」走向「真实执行含改动的代码路径」，是本轮最重要的工程能力进步。

**失 ——**

- 恢复「静默空操作」连过 4 轮测试才被发现——根因是验证长期停留在「逻辑复刻」而非「真实执行」。
- 教训：**验证必须执行真实代码路径，不能只复刻「正确版逻辑」**；这一条已固化为回归套件红线。

---

## 📁 项目结构

```text
HermesSync/
├── HermesSyncGUI.ps1          主程序（PowerShell 5.1 + Windows Forms，单文件）
├── 启动HermesSync.bat         一键启动器（双击即用，零改动原脚本）
├── Test-Core.ps1              核心逻辑测试
├── Test-Integration.ps1       集成测试（模拟数据，无 GUI）
├── Test-StopProcess.ps1       进程终止测试
├── favicon.ico                窗口图标
├── .gitignore                 忽略运行时产物
├── README.md                  本文件
└── （运行时自动生成）config.json / sync.log / Backups/ 等，首次运行创建
```

---

## 🛠️ 技术约束（贡献者必读）

- 必须使用 **PowerShell 5.1 兼容语法**（禁用 `??` / `?.` / `?:` 等 PS 7+ 语法）
- 必须使用 **UTF-8 BOM** 编码（PS 5.1 不支持 UTF-8 无 BOM 中文脚本）
- 变量命名避免 `$pid` / `$host` 等只读自动变量
- 不要使用 emoji 字符（PS 5.1 + Windows Forms 渲染失败，显示方块）
- 文件操作加 `-ErrorAction SilentlyContinue`，备份/恢复前加 `try/catch` 兜底
- **不要使用 `taskkill /T`**（会连工具自身一起杀掉）

---

## 📜 许可证

[MIT](LICENSE) © HermesSync Contributors

---

## 💡 致谢

工具的第一版由 `LongCat-2.0` 编制交接文档（v0.9-dev），并在本轮复盘中完成修复与可用性验证。
