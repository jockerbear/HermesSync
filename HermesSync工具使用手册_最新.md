# Hermes 一键同步工具 — 使用手册（最新版）

> 编制日期：2026-07-18（更新）  
> 状态：**已修复可用（v1.0-fixed）**  
> 适用程序：`HermesSyncGUI.ps1`（修复版，52,397 字节）  
> 取代：原 `E:\Documents\Hermes\SyncTool\HermesSync-交接文档.md`（该文档标注"开发暂停/阻塞"已过时，仅作历史参考）  
> 维护位置：`E:\BaiduSyncdisk\WorkBuddy\2026-07-18-03-11-10\HermesSync\`（WorkBuddy 工作空间）

---

## ⚠️ 0. 必读：本次更新带来的两项重要变化

### 0.1 备份格式已变更（影响旧备份恢复）
修复版改变了备份 ZIP 内部结构：现在每个源目录会被**包装一层源名**——

- `hermesDataDir` 的内容 → ZIP 内 `hermes-home\` 下
- `workspaceDir` 的内容 → ZIP 内 `Hermes\` 下

**后果**：你手里在修复前生成的旧备份（ZIP 顶层是拍平的 `state.db`/`sessions`/…，**没有** `hermes-home`/`Hermes` 文件夹）**无法被修复版恢复**。恢复时会弹「备份格式不兼容」并中止，不会静默出错。

> ✅ 解决办法：用修复版「存」一次，生成新格式备份后，再用「取」恢复即可。

### 0.2 恢复功能现在真正生效
旧版"恢复"只做存在性校验就报成功，实际**不覆盖、不清本地数据**（静默空操作）。修复版已修正为**真正的镜像覆盖**：先清空目标目录，再写入备份内容（本地新增、备份中不存在的文件会被清理）。

---

## 1. 项目背景

用户有**两台 Windows 设备**，通过**百度网盘定时备份 + 本工具手动同步**实现 Hermes Agent 跨设备同步。本工具目标：一个**双击即用、图形界面**的 Hermes 同步工具（体验对齐 CherryStudio 一键备份恢复）。

### 核心功能状态

| # | 需求 | 状态 |
|---|------|------|
| F1 | 图形界面（Windows Forms），双击运行 | ✅ |
| F2 | 「存」→ 备份本机 Hermes 数据到同步目录 | ✅ |
| F3 | 「取」→ 从同步目录恢复覆盖本机数据 | ✅（已修空操作） |
| F4 | 全量备份，不筛选子目录 | ✅ |
| F5 | Hermes 运行时能正常备份（无需手动关闭） | ✅（已修闪退/自伤） |
| F6 | 恢复前自动回滚快照，支持撤销 | ✅ |
| F7 | 备份 ZIP 完整性校验 | ✅ |
| F8 | 自动清理旧备份（保留最近 N 个） | ✅ |
| F9 | 系统级安装/卸载集成 | ❌ 待开发 |

---

## 2. 技术方案

### 2.1 架构概览

```
┌─────────────────────────────────────────────┐
│              HermesSyncGUI.ps1              │
├─────────────────────────────────────────────┤
│  [GUI] Windows Forms (PowerShell 5.1)      │
│  [备份] 扫描 → 压缩(源名包装) → 校验 → 复制 → 清理 │
│  [恢复] 查找 → 快照 → 解压 → 镜像覆盖 → 验证    │
├─────────────────────────────────────────────┤
│  [进程管理] 检测 Hermes → 优雅终止(WM_CLOSE→按PID强杀) │
├─────────────────────────────────────────────┤
│  [存储层]                                   │
│  · config.json          用户配置            │
│  · syncDir/*.zip        同步副本（主备份）  │
│  · Backups/*.zip        本地备份副本        │
│  · Backups/.rollback/   回滚快照            │
│  · sync.log             操作日志            │
└─────────────────────────────────────────────┘
```

### 2.2 备份流程（修复版）

```
[用户点击"存"]
    ↓
[1] 检测 Hermes 进程 → 弹窗"是否强制终止" → 用户确认（运行时也可备份）
    ↓
[2] 检测同步目录写入权限
    ↓
[3] 扫描 hermesDataDir + workspaceDir（排除 logs/.log/tmp/.git）
    ↓
[4] 复制文件到临时目录，按源名包装：
      hermesDataDir  → hermes-home\...
      workspaceDir   → Hermes\...
    构建 ZIP（HermesSync_YYYYMMDD_HHMMSS.zip）
    ↓
[5] ZIP 完整性校验（读取条目数）
    ↓
[6] 复制到 syncDir
    ↓
[7] 自动清理旧备份（超过 localBackupLimit 个时删除最旧）
    ↓
[完成]
```

### 2.3 恢复流程（修复版，已修正为空操作→镜像覆盖）

```
[用户点击"取"]
    ↓
[1] 检测 Hermes 进程 → 弹窗确认终止
    ↓
[2] 查找最新备份 ZIP
    ↓
[3] 冲突检测（本机数据 vs 备份时间戳）
    ↓
[4] 创建回滚快照（Backups/.rollback/rollback_timestamp）
    ↓
[5] 校验目标路径可写
    ↓
[6] 解压 ZIP → 检测顶层是否为 hermes-home/ + Hermes\ 新格式
      · 新格式：按文件夹名映射到 hermesDataDir / workspaceDir，
        先 Remove-Item 清空目标 → 再 Copy-Filtered 镜像覆盖
      · 旧格式（拍平）：弹「备份格式不兼容」→ 回滚 → 中止（不再静默空操作）
    ↓
[7] 关键文件验证（state.db、config.yaml 存在性）
    ↓
[8] 清理回滚快照（成功时）/ 自动回滚（失败时）
    ↓
[完成]
```

### 2.4 排除规则

以下文件/目录不备份：
- 目录：`logs`, `.git`
- 扩展名：`.log`, `.tmp`
- 前缀：`tmp*`

### 2.5 一键启动（推荐）

修复版目录已附带 `启动HermesSync.bat`，**双击即用**：

```
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HermesSyncGUI.ps1"
```

- `.bat` 与 `.ps1` 必须同目录（整包拷贝时一起带走）。
- 运行时背后会有一个 cmd 控制台窗口（GUI 关闭后自动消失），属正常现象。
- 不需要目标机装任何额外运行时（Windows 自带 powershell.exe），无杀软误报风险。

> 若要手动启动：右键 `HermesSyncGUI.ps1` → 用 PowerShell 运行；或在 PowerShell 中
> `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "路径\HermesSyncGUI.ps1"`。

---

## 3. 文件清单（修复版）

```
E:\Documents\Hermes\HermesSync_修复版\
├── HermesSyncGUI.ps1         主程序（修复版，UTF-8 BOM，PS 5.1）
├── 启动HermesSync.bat         一键启动器（双击即用）
├── config.json               用户配置（首次运行自动生成）
├── sync.log                  操作日志
├── HermesSyncGUI.ps1.orig    原始未修复副本（参考）
├── Backups\                  本地备份副本
│   ├── HermesSync_*.zip       备份 ZIP（注意：旧格式 3 个无法被新工具恢复）
│   └── .rollback\            回滚快照
└──（测试脚本若干）
```

> ⚠️ 不要使用 `E:\Documents\Hermes\SyncTool\HermesSyncGUI.ps1`——那是**未修复的原始版本**，仍存在运行阻塞与恢复空操作。

### 3.1 config.json 结构

```json
{
    "hermesDataDir": "D:\\Program Files\\Hermes Agent CN Desktop\\data\\hermes-home",
    "workspaceDir": "E:\\Documents\\Hermes",
    "syncDir": "",
    "localBackupLimit": 5,
    "firstRun": true,
    "lastBackupTime": "",
    "lastBackupPath": ""
}
```

### 3.2 主要函数（行号随修复变动，以源码为准）

| 函数 | 用途 |
|------|------|
| `Get-DefaultConfig` / `Load-Config` / `Save-Config` | 配置读写（Load-Config 已修枚举改表缺陷） |
| `Get-HermesProcesses` / `Stop-HermesProcesses` | 进程检测与优雅终止（按 PID，不自伤） |
| `Test-DirectoryWriteable` | 写入权限检查 |
| `Copy-Filtered` | 带排除规则的复制 |
| `Start-BackupProcess` | 备份主流程（已加源名层 + $startTime） |
| `Start-RestoreProcess` | 恢复主流程（已修正镜像覆盖 + 旧格式拒绝） |
| `Invoke-Rollback` | 回滚操作 |
| `Show-FirstRunConfig` / `Show-MainForm` / `Main` | GUI 与入口 |

---

## 4. 使用说明

### 4.1 首次启动
- 双击 `启动HermesSync.bat`（或 `HermesSyncGUI.ps1`）。
- 首次或 `syncDir` 为空时自动弹出配置向导；配置保存后 `firstRun=false`，之后不再弹（设计行为，非 bug）。

### 4.2 配置项
- **同步目录**：选百度网盘文件夹 / U 盘（如 `F:\`），备份 ZIP 复制到这里以便跨设备同步。**此项必须设置**，否则备份会被拦截并提示。
- **Hermes 数据目录**：默认 `D:\Program Files\Hermes Agent CN Desktop\data\hermes-home`。
- **工作空间目录**：默认 `E:\Documents\Hermes`。
- **本地备份保留份数**：默认 5（超过自动删最旧）。

### 4.3 备份（「存」）
1. 点主界面绿色「存 · 备份本机」。
2. 弹窗确认输出位置（同步目录）→ 点「确认开始备份？」。
3. 流程：终止 Hermes → 权限检查 → 扫描 → 压缩（源名包装）→ 校验 → 复制到同步目录 → 清理旧备份。
4. 完成后在 `同步目录` 生成 `HermesSync_YYYYMMDD_HHmmss.zip`，并在 `Backups\` 留本地副本。
5. 请等网盘同步完成后再去另一台设备恢复。

### 4.4 恢复（「取」）— 现已真正生效
1. 点蓝色「取 · 恢复数据」。
2. 弹窗确认使用的最新备份 → 点「确认继续？」。
3. **新格式备份**：解压 → 镜像覆盖（先清空 `hermesDataDir`/`workspaceDir` 再写入备份内容）→ 校验 → 完成。本地新增、备份中不存在的文件会被清理。
4. **旧格式备份（修复前生成）**：弹「备份格式不兼容」并中止，不会误清数据。请改用新工具重新「存」后恢复。
5. 若恢复异常，自动回滚到操作前快照（`Backups\.rollback\`）。

### 4.5 回滚快照
- 每次恢复前在 `Backups\.rollback\rollback_YYYYMMDD_HHmmss\` 保存操作前快照；失败时自动回滚。

### 4.6 已知限制
- ⚠️ **workspaceDir 范围过大**：默认整包 `E:\Documents\Hermes`（含工具自身及其它项目），备份体积较大（最新约 142 MB），且镜像恢复会清掉该目录内不在备份中的文件。后续计划收敛范围。
- 旧备份（修复前）不兼容，需重新「存」。
- 安装/卸载（F9）、增量备份、计划任务自动备份尚未开发。

---

## 5. 已修复的关键历史问题（供排错参考）

| 问题 | 现象 | 根因 | 处置 |
|---|---|---|---|
| Hermes 运行时备份失败/闪退 | 点「存」报"无法终止"或工具闪退 | 按名杀误伤自身；外部杀手未生效主进程已 Exit | 仅按 PID 优雅终止，失败返回 false |
| 设置后报"同步目录未配置" | 已设同步目录仍提示未配置 | 闭包内 `$config` 作用域不共享 | 改用 `$script:config` |
| Load-Config 恒返回默认 | 保存的 syncDir 读不回 | 枚举期改表被 catch 静默吞 | 键快照后遍历 |
| 备份报"未能找到路径" | 首跑 CreateFromDirectory 失败 | 备份/回滚目录未创建 | 压缩前建目录守卫 |
| 备份末尾"Subtract 重载" | 备份成功却报失败 | `$startTime` 未定义 | 补定义 |
| 恢复不覆盖本地新增 | 恢复后本地新对话仍在 | 备份拍平 vs 恢复按名匹配 → 空操作 | 备份加源名层 + 旧格式拒绝 |
| 备份"哈希 Null 键" | 压缩步骤报错 | 哈希字面量内写赋值（运行时错） | 移出哈希表外 |

---

## 6. 环境约束

| 项目 | 值 |
|------|---|
| 操作系统 | Windows 10/11 64-bit |
| PowerShell 版本 | 5.1（系统内置） |
| 运行时 | .NET Framework（系统自带） |
| Hermes 数据目录 | `D:\Program Files\Hermes Agent CN Desktop\data\hermes-home` |
| 工作空间 | `E:\Documents\Hermes` |
| 同步工具目录（修复版） | `E:\Documents\Hermes\HermesSync_修复版\` |
| Hermes 进程名 | `hermes-agent-cn-runtime-win32-x64` |

---

## 7. 开发注意事项（延续交接文档）

1. 必须使用 PowerShell 5.1 兼容语法（无 `??`、`?.`、`?:` 等 PS 7+ 语法）。
2. 必须使用 UTF-8 BOM 编码（PS 5.1 中文脚本要求）。
3. 变量命名避免 `$pid`、`$host` 等只读自动变量。
4. 不要使用 emoji 字符（PS 5.1 + Windows Forms 渲染失败）。
5. **哈希字面量 `@{...}` 内禁止写赋值语句**（会把键位变量求值为 $null 报 Null 键，且是运行时错误，语法解析查不出）。
6. **验证必须真实执行含改动的代码路径**（用 `Invoke-Expression` 提取真实源码片段运行），不能只复刻"正确版逻辑"。
7. 备份/恢复前加 `try/catch` 兜底；所有文件操作加 `-ErrorAction` 处理。
8. 不要使用 `taskkill /T`（会连工具自身一起杀掉）。

---

## 8. 相关资源

- 原始（未修复）基线：`E:\Documents\Hermes\SyncTool\HermesSyncGUI.ps1`
- 修复版（请用这个）：`E:\Documents\Hermes\HermesSync_修复版\`
- 开发报告（得与失复盘）：`HermesSync开发报告_得与失_20260718.md`
- 测试套件（工作空间 `HermesSync\` 目录）：`regression_test.ps1`、`qa_restore_contract.ps1`、`restore_e2e_test.ps1`、`mirror_restore_test.ps1`、`qa_nullkey_indep.ps1` 等

---

**手册版本**：v1.0-fixed（最新）  
**最后更新**：2026-07-18  
**下一步**：收敛 `workspaceDir` 备份范围；旧备份一键重新存；安装/卸载集成
