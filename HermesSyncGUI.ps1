#Requires -Version 5.1
param([switch]$TestMode)
<#
.SYNOPSIS
    Hermes 一键同步工具 - 图形化备份恢复工具
.DESCRIPTION
    双击即用的 Hermes 数据同步工具，支持备份（存）和恢复（取）操作。
    包含完整的容错机制：冲突检测、快照回滚、完整性校验。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ============================================================
# 全局配置
# ============================================================
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile   = Join-Path $ScriptDir "config.json"
$LogFile      = Join-Path $ScriptDir "sync.log"
$BackupDir    = Join-Path $ScriptDir "Backups"
$RollbackDir  = Join-Path $BackupDir ".rollback"
$MutexName    = "HermesSyncTool_SingleInstance"

# ============================================================
# 日志系统
# ============================================================
function Write-SyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    return $entry
}

function Show-Log {
    param([string]$Text, [string]$Color = "White")
    if ($script:LogTextBox -and $script:LogTextBox.InvokeRequired) {
        $script:LogTextBox.Invoke([Action]{ param($t,$c) Show-Log -Text $t -Color $c }, $Text, $Color)
    } else {
        if ($script:LogTextBox) {
            $script:LogTextBox.AppendText("`r`n$Text")
            $script:LogTextBox.ScrollToCaret()
        }
    }
}

# ============================================================
# 配置管理
# ============================================================
function Get-DefaultConfig {
    return @{
        hermesDataDir = "D:\Program Files\Hermes Agent CN Desktop\data\hermes-home"
        workspaceDir  = "E:\Documents\Hermes"
        syncDir       = ""
        localBackupLimit = 5
        firstRun      = $true
        lastBackupTime = ""
        lastBackupPath = ""
    }
}

function Load-Config {
    if (Test-Path $ConfigFile) {
        try {
            $loaded = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:config = Get-DefaultConfig
            $keys = @($script:config.Keys)
            foreach ($key in $keys) {
                if ($loaded.PSObject.Properties[$key]) { $script:config[$key] = $loaded.$key }
            }
            return $script:config
        } catch { return Get-DefaultConfig }
    }
    return Get-DefaultConfig
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 3 | Out-File $ConfigFile -Encoding UTF8 -Force
}

# ============================================================
# 工具函数
# ============================================================
function Get-HermesProcesses {
    # 返回所有 Hermes 相关进程对象（含 watchdog/launcher），排除自身
    $scriptPid = $PID
    $byName = @(Get-Process | Where-Object { ($_.ProcessName -like "*hermes*") -and ($_.Id -ne $scriptPid) })
    # 通过命令行捕获名字不含 hermes 的 watchdog/launcher 包装进程
    $byCmd = @()
    try {
        $wmi = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue
        foreach ($w in $wmi) {
            if ($w.CommandLine -and ($w.CommandLine -like "*hermes-agent*") -and ($w.ProcessId -ne $scriptPid)) {
                $p = Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue
                if ($p) { $byCmd += $p }
            }
        }
    } catch {}
    $map = @{}
    foreach ($p in ($byName + $byCmd)) { $map[$p.Id] = $p }
    return @($map.Values)
}

function Get-HermesProcessIds {
    # 兼容包装：返回 PID 列表
    return @(Get-HermesProcesses | ForEach-Object { $_.Id })
}

function Stop-ProcessList {
    param([int[]]$ProcessIds)
    # 只按 PID 强制终止（Stop-Process + WMI Terminate），跳过自身；绝不按镜像名杀，避免误杀 powershell/cmd 等共享宿主
    if (-not $ProcessIds -or $ProcessIds.Count -eq 0) { return $true }
    $scriptPid = $PID
    foreach ($id in $ProcessIds) {
        if ($id -eq $scriptPid) { continue }
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
        try {
            $w = Get-WmiObject Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue
            if ($w) { $w.Terminate() | Out-Null }
        } catch {}
    }
    return $true
}

function Stop-HermesProcesses {
    param([int]$TimeoutSeconds = 30)
    $scriptPid = $PID
    # 阶段1：优雅关闭（方案A - 向主窗口发 WM_CLOSE，让 Hermes 自己清理）
    $initial = Get-HermesProcesses
    foreach ($p in $initial) {
        try { if (-not $p.HasExited) { $null = $p.CloseMainWindow() } } catch {}
    }
    if ($initial -and $initial.Count -gt 0) { Start-Sleep -Seconds 3 }

    # 阶段2：强力终止循环（仅按 PID 杀，覆盖 watchdog 重启竞争；不按镜像名杀，避免误杀自身/共享宿主）
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $procs = Get-HermesProcesses
        if (-not $procs -or $procs.Count -eq 0) { return $true }
        $ids = @($procs | ForEach-Object { $_.Id } | Where-Object { $_ -ne $scriptPid })
        Stop-ProcessList -ProcessIds $ids | Out-Null
        Start-Sleep -Seconds 1
    }
    $remaining = Get-HermesProcesses
    if (-not $remaining -or $remaining.Count -eq 0) { return $true }
    # 失败：返回 $false，由调用方弹「手动关闭」提示（不再走 RESTART 闪退路径）
    $details = ($remaining | ForEach-Object { "$($_.ProcessName) (PID: $($_.Id))" }) -join ", "
    Show-Log -Text "  [警告] 无法终止 Hermes 进程: $details" -Color "Red"
    return $false
}

function Test-DirectoryWriteable {
    param([string]$Path)
    if (-not $Path -or $Path.Trim() -eq "") { return $false }
    if (-not (Test-Path $Path)) { return $false }
    $testFile = Join-Path $Path "_test_$(Get-Random).tmp"
    try {
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    return (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
}

function Format-Size {
    param($Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-Exclusions {
    @("logs", "*.log", "*.tmp", "*.cache", ".vs", "__pycache__", "node_modules", ".rollback")
}

function Test-ShouldExclude {
    param([string]$ItemName)
    # ItemName can be either a full path or just a filename
    $name = Split-Path $ItemName -Leaf
    $exclusions = Get-Exclusions
    foreach ($excl in $exclusions) {
        if ($excl.StartsWith("*")) {
            if ($name -like $excl) { return $true }
        } elseif ($name -eq $excl) { return $true }
    }
    # Also exclude filenames starting with tmp
    if ($name -like "tmp*") { return $true }
    return $false
}

# ============================================================
# 核心：备份流程
# ============================================================
function Start-BackupProcess {
    param($Config, [System.Windows.Forms.Label]$StatusLabel, [System.Windows.Forms.ProgressBar]$ProgressBar)
    
    try {
        $startTime = Get-Date
        # 1. 进程检测
        Update-Status -Label $StatusLabel -Text "检测进程..." -Color "Yellow"
        Show-Log -Text "[步骤1/7] 检测 Hermes 进程..."
        $procs = Get-HermesProcesses
        if ($procs) {
            $procNames = ($procs | Select-Object -ExpandProperty ProcessName) -join ", "
            $result = [System.Windows.Forms.MessageBox]::Show(
                "检测到 Hermes 进程正在运行：$procNames`n`n需要关闭 Hermes 才能完整备份所有文件。`n确认将强制终止所有 Hermes 进程并继续备份？`n（未保存的对话将丢失！）",
                "进程警告", "YesNo", "Warning")
            if ($result -eq "No") {
                Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
                Show-Log -Text "用户取消备份" -Color "Red"
                return $false
            }
            # 强制终止 Hermes 进程（使用多策略：进程树→taskkill→Stop-Process）
            Show-Log -Text "  [操作] 正在终止 Hermes 进程..." -Color "Yellow"
            $stopResult = Stop-HermesProcesses
            if ($stopResult -eq $false) {
                [System.Windows.Forms.MessageBox]::Show(
                    "部分 Hermes 进程无法终止，请手动关闭后重试。",
                    "终止失败", "OK", "Error")
                Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
                Show-Log -Text "进程终止失败" -Color "Red"
                return $false
            }
            Show-Log -Text "  所有 Hermes 进程已终止" -Color "Green"
        } else {
            Show-Log -Text "  进程检查通过" -Color "Green"
        }
        
        # 2.0 同步目录空值引导
        if (-not $Config.syncDir -or $Config.syncDir.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show(
                "同步目录尚未配置，无法备份。`n请点击主界面右上角 [设置] 按钮，选择百度网盘文件夹或 U 盘作为同步目录。",
                "同步目录未设置", "OK", "Warning")
            Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
            Show-Log -Text "同步目录为空，已引导用户配置" -Color "Yellow"
            return $false
        }
        
        # 2. 权限检测
        Update-Status -Label $StatusLabel -Text "检测权限..." -Color "Yellow"
        Show-Log -Text "[步骤2/7] 检测写入权限..."
        if (-not (Test-DirectoryWriteable $Config.syncDir)) {
            [System.Windows.Forms.MessageBox]::Show(
                "无法写入同步目录：$($Config.syncDir)`n请检查网盘是否运行或更换同步目录。",
                "权限不足", "OK", "Error")
            Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
            Show-Log -Text "同步目录无写入权限" -Color "Red"
            return $false
        }
        Show-Log -Text "  权限检查通过" -Color "Green"
        
        # 3. 数据扫描
        Update-Status -Label $StatusLabel -Text "扫描数据..." -Color "Yellow"
        Show-Log -Text "[步骤3/7] 扫描数据..."
        $sources = @($Config.hermesDataDir, $Config.workspaceDir)
        $totalFiles = 0
        $totalSize = 0
        foreach ($src in $sources) {
            if (Test-Path $src) {
                $items = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-ShouldExclude $_.FullName) }
                $count = ($items | Measure-Object).Count
                $size = ($items | Measure-Object -Property Length -Sum).Sum
                $totalFiles += $count
                $totalSize += $size
                Show-Log -Text "  [目录] $(Format-Size $size) / $count 个文件 : $(Split-Path $src -Leaf)"
            }
        }
        Show-Log -Text "  [总计] $(Format-Size $totalSize) / $totalFiles 个文件"
        
        # 4. 压缩打包
        Update-Status -Label $StatusLabel -Text "压缩打包..." -Color "Yellow"
        Show-Log -Text "[步骤4/7] 压缩打包..."
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $zipName = "HermesSync_$timestamp.zip"
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $localZip = Join-Path $BackupDir $zipName
        
        # 收集要压缩的文件
        $allFiles = @()
        foreach ($src in $sources) {
            if (Test-Path $src) {
                $files = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-ShouldExclude $_.FullName) }
                foreach ($f in $files) {
                    $srcLeaf = Split-Path $src -Leaf
                    $rel = $f.FullName.Substring($src.Length).TrimStart("\")
                    $allFiles += [PSCustomObject]@{
                        FullName = $f.FullName
                        Relative = "$srcLeaf\$rel"
                        Source = $src
                    }
                }
            }
        }
        
        if ($allFiles.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("没有找到可备份的文件。", "无数据", "OK", "Warning")
            Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
            return $false
        }
        
        # 使用临时目录构建 ZIP
        $tempDir = Join-Path $env:TEMP "HermesSync_$timestamp"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        $done = 0
        $errors = @()
        foreach ($f in $allFiles) {
            $done++
            $pct = [math]::Min(99, [math]::Round(($done / $allFiles.Count) * 99))
            Update-Progress -ProgressBar $ProgressBar -Value $pct -Text "压缩中... $done / $($allFiles.Count)"
            
            try {
                $destDir = Join-Path $tempDir (Split-Path $f.Relative -Parent)
                if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                Copy-Item $f.FullName (Join-Path $destDir (Split-Path $f.Relative -Leaf)) -Force -ErrorAction Stop
            } catch {
                $errors += $f.Relative
            }
        }
        
        if ($errors.Count -gt 0) {
            Show-Log -Text "  [警告] $($errors.Count) 个文件复制失败" -Color "Yellow"
        }
        
        # 创建 ZIP
        if (Test-Path $localZip) { Remove-Item $localZip -Force -ErrorAction SilentlyContinue }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $localZip, "Optimal", $false)
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        
        $zipSize = (Get-Item $localZip).Length
        Show-Log -Text "  ZIP 创建完成: $(Format-Size $zipSize)" -Color "Green"
        
        # 5. 完整性校验
        Update-Status -Label $StatusLabel -Text "校验完整性..." -Color "Yellow"
        Show-Log -Text "[步骤5/7] 校验压缩包完整性..."
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($localZip)
            $entries = $zip.Entries
            $zip.Dispose()
            Show-Log -Text "  [通过] 校验通过（$($entries.Count) 个文件）" -Color "Green"
        } catch {
            Remove-Item $localZip -Force -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show("ZIP 文件校验失败，请重试。", "校验失败", "OK", "Error")
            Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
            return $false
        }
        
        # 6. 双份输出
        Update-Status -Label $StatusLabel -Text "复制到同步目录..." -Color "Yellow"
        Show-Log -Text "[步骤6/7] 复制到同步目录..."
        $syncZip = Join-Path $Config.syncDir $zipName
        Copy-Item $localZip $syncZip -Force -ErrorAction Stop
        Show-Log -Text "  同步目录副本完成" -Color "Green"
        Show-Log -Text "  [同步目录] $($Config.syncDir)" -Color "White"
        
        # 7. 自动清理
        Update-Status -Label $StatusLabel -Text "清理旧备份..." -Color "Yellow"
        Show-Log -Text "[步骤7/7] 清理旧备份..."
        $backups = Get-ChildItem $BackupDir -Filter "HermesSync_*.zip" | Sort-Object LastWriteTime -Descending
        if ($backups.Count -gt $Config.localBackupLimit) {
            $toDelete = $backups | Select-Object -Skip $Config.localBackupLimit
            foreach ($b in $toDelete) {
                Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue
                Show-Log -Text "  🗑 清理旧备份: $($b.Name)" -Color "Yellow"
            }
        }
        $remaining = (Get-ChildItem $BackupDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Measure-Object).Count
        $totalUsed = (Get-ChildItem $BackupDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Show-Log -Text "  [备份] 本地备份：$remaining / $($Config.localBackupLimit)，占用 $(Format-Size $totalUsed)" -Color "White"
        
        # 更新配置
        $Config.lastBackupTime = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $Config.lastBackupPath = $syncZip
        Save-Config $Config
        
        # 完成
        Update-Progress -ProgressBar $ProgressBar -Value 100 -Text "完成"
        Update-Status -Label $StatusLabel -Text "完成" -Color "Green"
        Show-Log -Text "========== 备份完成 ==========" -Color "Green"
        Show-Log -Text "文件: $zipName" -Color "Green"
        Show-Log -Text "大小: $(Format-Size $zipSize)" -Color "Green"
        Show-Log -Text "耗时: $([math]::Round((Get-Date).Subtract($startTime).TotalSeconds)) 秒" -Color "Green"
        
        [System.Windows.Forms.MessageBox]::Show(
            "备份完成！`n`n文件: $zipName`n大小: $(Format-Size $zipSize)`n同步目录: $($Config.syncDir)`n`n请等待网盘同步完成后再在其他设备恢复。",
            "备份完成", "OK", "Information")
        
        return $true
        
    } catch {
        Update-Status -Label $StatusLabel -Text "✗ 失败" -Color "Red"
        Show-Log -Text "备份失败: $_" -Color "Red"
        [System.Windows.Forms.MessageBox]::Show("备份失败:`n$_", "错误", "OK", "Error")
        return $false
    }
}

# ============================================================
# 核心：恢复流程
# ============================================================
function Start-RestoreProcess {
    param($Config, [System.Windows.Forms.Label]$StatusLabel, [System.Windows.Forms.ProgressBar]$ProgressBar)
    
    try {
        $startTime = Get-Date
        
        # 1. 进程检测
        Update-Status -Label $StatusLabel -Text "检测进程..." -Color "Yellow"
        Show-Log -Text "[步骤1/8] 检测 Hermes 进程..."
        $procs = Get-HermesProcesses
        if ($procs) {
            $procNames = ($procs | Select-Object -ExpandProperty ProcessName) -join ", "
            $result = [System.Windows.Forms.MessageBox]::Show(
                "检测到 Hermes 进程正在运行：$procNames`n`n需要关闭 Hermes 才能完整恢复所有文件。`n确认将强制终止所有 Hermes 进程并继续恢复？`n（未保存的对话将丢失！）",
                "进程警告", "YesNo", "Warning")
            if ($result -eq "No") {
                Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
                Show-Log -Text "用户取消恢复" -Color "Red"
                return $false
            }
            # 强制终止 Hermes 进程（使用多策略：进程树→taskkill→Stop-Process）
            Show-Log -Text "  [操作] 正在终止 Hermes 进程..." -Color "Yellow"
            $stopResult = Stop-HermesProcesses
            if ($stopResult -eq $false) {
                [System.Windows.Forms.MessageBox]::Show(
                    "部分 Hermes 进程无法终止，请手动关闭后重试。",
                    "终止失败", "OK", "Error")
                Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
                Show-Log -Text "进程终止失败" -Color "Red"
                return $false
            }
            Show-Log -Text "  所有 Hermes 进程已终止" -Color "Green"
        } else {
            Show-Log -Text "  进程检查通过" -Color "Green"
        }
        
        # 2. 查找备份文件
        Update-Status -Label $StatusLabel -Text "查找备份..." -Color "Yellow"
        Show-Log -Text "[步骤2/8] 查找可用备份..."
        $backups = Get-ChildItem $Config.syncDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if (-not $backups -or $backups.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "在同步目录中未找到备份文件。`n请确保同步目录设置正确且网盘已同步。",
                "无备份", "OK", "Warning")
            Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
            Show-Log -Text "未找到备份文件" -Color "Red"
            return $false
        }
        $latest = $backups[0]
        Show-Log -Text "  [备份] 找到 $($backups.Count) 个备份，使用最新：$($latest.Name)" -Color "Green"
        
        # 3. 冲突检测
        Update-Status -Label $StatusLabel -Text "冲突检测..." -Color "Yellow"
        Show-Log -Text "[步骤3/8] 检测数据冲突..."
        $stateDbPath = Join-Path $Config.hermesDataDir "state.db"
        if (Test-Path $stateDbPath) {
            $localTime = (Get-Item $stateDbPath).LastWriteTime
            $bakTime = $latest.LastWriteTime
            if ($localTime -gt $bakTime) {
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "检测到本机数据比备份更新！`n`n" +
                    "本机对话最后修改: $($localTime.ToString('yyyy-MM-dd HH:mm:ss'))`n" +
                    "备份时间: $($bakTime.ToString('yyyy-MM-dd HH:mm:ss'))`n`n" +
                    "建议先到另一台电脑执行「存」操作。`n" +
                    "如确认覆盖，本机最新数据将丢失！",
                    "冲突警告", "YesNo", "Warning")
                if ($result -eq "No") {
                    Update-Status -Label $StatusLabel -Text "待操作" -Color "White"
                    Show-Log -Text "用户取消恢复" -Color "Yellow"
                    return $false
                }
                Show-Log -Text "  ⚠ 用户确认覆盖" -Color "Yellow"
            } else {
                Show-Log -Text "  无冲突" -Color "Green"
            }
        }
        
        # 4. 快照回滚
        Update-Status -Label $StatusLabel -Text "创建回滚快照..." -Color "Yellow"
        Show-Log -Text "[步骤4/8] 创建回滚快照..."
        $rollbackTs = Get-Date -Format "yyyyMMdd_HHmmss"
        if (-not (Test-Path $RollbackDir)) { New-Item -ItemType Directory -Path $RollbackDir -Force | Out-Null }
        $rollbackPath = Join-Path $RollbackDir "rollback_$rollbackTs"
        if (Test-Path $rollbackPath) { Remove-Item $rollbackPath -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $rollbackPath -Force | Out-Null
        
        $snapshotSources = @($Config.hermesDataDir, $Config.workspaceDir)
        foreach ($src in $snapshotSources) {
            if (Test-Path $src) {
                $folderName = Split-Path $src -Leaf
                $destSrc = Join-Path $rollbackPath $folderName
                Copy-Filtered -Source $src -Destination $destSrc -ProgressBar $ProgressBar
            }
        }
        Show-Log -Text "  快照保存到: rollback_$rollbackTs" -Color "Green"
        
        # 5. 路径校验
        Update-Status -Label $StatusLabel -Text "校验目标路径..." -Color "Yellow"
        Show-Log -Text "[步骤5/8] 校验目标路径..."
        $needsPathPrompt = $false
        if (-not (Test-Path $Config.hermesDataDir)) { $needsPathPrompt = $true }
        if (-not (Test-Path $Config.workspaceDir)) { $needsPathPrompt = $true }
        
        if ($needsPathPrompt) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "目标路径不存在，是否手动指定新路径？`n" +
                "Hermes目录: $($Config.hermesDataDir)`n" +
                "工作空间: $($Config.workspaceDir)",
                "路径缺失", "YesNo", "Warning")
            if ($result -eq "Yes") {
                # 简化处理：让用户选择 Hermes 根目录
                $dirBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
                $dirBrowser.Description = "选择 Hermes 数据目录（hermes-home 所在位置）"
                if ($dirBrowser.ShowDialog() -eq "OK") {
                    $Config.hermesDataDir = $dirBrowser.SelectedPath
                    Save-Config $Config
                    Show-Log -Text "  更新 Hermes 目录: $($Config.hermesDataDir)" -Color "Yellow"
                }
            }
        }
        Show-Log -Text "  路径校验通过" -Color "Green"
        
        # 6. 解压覆盖
        Update-Status -Label $StatusLabel -Text "解压覆盖..." -Color "Yellow"
        Show-Log -Text "[步骤6/8] 解压并覆盖..."
        $extractTemp = Join-Path $env:TEMP "HermesRestore_$rollbackTs"
        if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
        
        try {
            Expand-Archive -Path $latest.FullName -DestinationPath $extractTemp -Force -ErrorAction Stop
            Show-Log -Text "  解压完成" -Color "Green"
        } catch {
            # 回滚
            Show-Log -Text "  ✗ 解压失败: $_" -Color "Red"
            Invoke-Rollback -RollbackPath $rollbackPath -Config $Config
            Update-Status -Label $StatusLabel -Text "✗ 失败(已回滚)" -Color "Red"
            return $false
        }
        
        # 覆盖到目标位置
        $extractFolders = Get-ChildItem $extractTemp -Directory -ErrorAction SilentlyContinue
        $hasNamedRoot = $extractFolders | Where-Object { $_.Name -eq "hermes-home" -or $_.Name -eq "Hermes" }
        if (-not $hasNamedRoot) {
            [System.Windows.Forms.MessageBox]::Show(
                "检测到旧格式备份（无目录结构），无法安全恢复。`n请先在源设备重新执行「存」操作生成新备份后再取回。",
                "备份格式不兼容", "OK", "Warning")
            Invoke-Rollback -RollbackPath $rollbackPath -Config $Config
            Update-Status -Label $StatusLabel -Text "✗ 失败(已回滚)" -Color "Red"
            return $false
        }
        foreach ($folder in $extractFolders) {
            $targetPath = ""
            if ($folder.Name -eq "hermes-home") {
                $targetPath = $Config.hermesDataDir
            } elseif ($folder.Name -eq "Hermes") {
                $targetPath = $Config.workspaceDir
            }
            
            if ($targetPath -and (Test-Path $folder.FullName)) {
                Show-Log -Text "  正在镜像覆盖: $(Split-Path $targetPath -Leaf)..." -Color "Yellow"
                try {
                    # 镜像还原：先清空目标目录现有内容（回滚快照已在步骤4保存，可一键恢复）
                    if (Test-Path $targetPath) {
                        Remove-Item -Path $targetPath -Recurse -Force -ErrorAction Stop
                    }
                    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                    Copy-Filtered -Source $folder.FullName -Destination $targetPath -ProgressBar $ProgressBar
                } catch {
                    Invoke-Rollback -RollbackPath $rollbackPath -Config $Config
                    Update-Status -Label $StatusLabel -Text "✗ 失败(已回滚)" -Color "Red"
                    [System.Windows.Forms.MessageBox]::Show("覆盖失败，已自动回滚到操作前状态。", "失败", "OK", "Error")
                    return $false
                }
            }
        }
        
        # 7. 结果验证
        Update-Status -Label $StatusLabel -Text "验证结果..." -Color "Yellow"
        Show-Log -Text "[步骤7/8] 验证结果..."
        $stateDb = Join-Path $Config.hermesDataDir "state.db"
        $configYaml = Join-Path $Config.hermesDataDir "config.yaml"
        
        $verified = $true
        if (-not (Test-Path $stateDb)) {
            Show-Log -Text "  ✗ state.db 缺失" -Color "Red"
            $verified = $false
        }
        if (-not (Test-Path $configYaml)) {
            Show-Log -Text "  ✗ config.yaml 缺失" -Color "Red"
            $verified = $false
        }
        
        if (-not $verified) {
            Show-Log -Text "  ✗ 关键文件缺失，执行回滚！" -Color "Red"
            Invoke-Rollback -RollbackPath $rollbackPath -Config $Config
            Update-Status -Label $StatusLabel -Text "✗ 失败(已回滚)" -Color "Red"
            [System.Windows.Forms.MessageBox]::Show("关键文件缺失，已自动回滚到操作前状态。", "失败", "OK", "Error")
            return $false
        }
        Show-Log -Text "  关键文件验证通过" -Color "Green"
        
        # 8. 清理快照
        Update-Status -Label $StatusLabel -Text "清理临时文件..." -Color "Yellow"
        Show-Log -Text "[步骤8/8] 清理临时文件..."
        if (Test-Path $rollbackPath) { Remove-Item $rollbackPath -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
        
        # 完成
        Update-Progress -ProgressBar $ProgressBar -Value 100 -Text "完成"
        Update-Status -Label $StatusLabel -Text "完成" -Color "Green"
        Show-Log -Text "========== 恢复完成 ==========" -Color "Green"
        Show-Log -Text "使用备份: $($latest.Name)" -Color "Green"
        Show-Log -Text "创建时间: $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Color "Green"
        Show-Log -Text "耗时: $([math]::Round((Get-Date).Subtract($startTime).TotalSeconds)) 秒" -Color "Green"
        
        [System.Windows.Forms.MessageBox]::Show(
            "恢复完成！`n`n使用备份: $($latest.Name)`n创建时间: $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))`n`n现在可以启动 Hermes 了。",
            "恢复完成", "OK", "Information")
        
        return $true
        
    } catch {
        Update-Status -Label $StatusLabel -Text "✗ 失败" -Color "Red"
        Show-Log -Text "恢复失败: $_" -Color "Red"
        [System.Windows.Forms.MessageBox]::Show("恢复失败:`n$_", "错误", "OK", "Error")
        return $false
    }
}

function Copy-Filtered {
    param([string]$Source, [string]$Destination, [System.Windows.Forms.ProgressBar]$ProgressBar)
    
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    
    $files = Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-ShouldExclude $_.FullName) }
    $total = ($files | Measure-Object).Count
    $done = 0
    
    foreach ($f in $files) {
        $done++
        $relPath = $f.FullName.Substring($Source.Length).TrimStart("\")
        $destFile = Join-Path $Destination $relPath
        $destDir = Split-Path $destFile -Parent
        
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $f.FullName $destFile -Force -ErrorAction SilentlyContinue
        
        if ($ProgressBar -and ($done % 10 -eq 0 -or $done -eq $total)) {
            $pct = [math]::Min(99, [math]::Round(($done / $total) * 99))
            Update-Progress -ProgressBar $ProgressBar -Value $pct -Text "复制中... $done / $total"
        }
    }
}

function Invoke-Rollback {
    param($RollbackPath, $Config)
    Show-Log -Text "[回滚] 正在恢复到操作前状态..." -Color "Red"
    Copy-Filtered -Source (Join-Path $RollbackPath "hermes-home") -Destination $Config.hermesDataDir
    Copy-Filtered -Source (Join-Path $RollbackPath "Hermes") -Destination $Config.workspaceDir
    Show-Log -Text "[回滚] 已恢复" -Color "Green"
}

# ============================================================
# GUI 辅助
# ============================================================
function Update-Status {
    param([System.Windows.Forms.Label]$Label, [string]$Text, [string]$Color)
    if ($Label -and -not $Label.IsDisposed) {
        if ($Label.InvokeRequired) {
            $Label.Invoke([Action]{ Update-Status -Label $Label -Text $Text -Color $Color })
        } else {
            $Label.Text = "  $Text"
            switch ($Color) {
                "White"  { $Label.ForeColor = [System.Drawing.Color]::White }
                "Yellow" { $Label.ForeColor = [System.Drawing.Color]::Yellow }
                "Green"  { $Label.ForeColor = [System.Drawing.Color]::Lime }
                "Red"    { $Label.ForeColor = [System.Drawing.Color]::Red }
            }
        }
    }
}

function Update-Progress {
    param([System.Windows.Forms.ProgressBar]$ProgressBar, [int]$Value, [string]$Text = "")
    if ($ProgressBar -and -not $ProgressBar.IsDisposed) {
        if ($ProgressBar.InvokeRequired) {
            $ProgressBar.Invoke([Action]{ Update-Progress -ProgressBar $ProgressBar -Value $Value -Text $Text })
        } else {
            $ProgressBar.Value = [math]::Min(100, [math]::Max(0, $Value))
            if ($Text) { $ProgressBar.Tag = $Text }
        }
    }
}

function Enable-Buttons {
    param([bool]$Enable)
    if ($script:BtnBackup -and -not $script:BtnBackup.IsDisposed) {
        if ($script:BtnBackup.InvokeRequired) {
            $script:BtnBackup.Invoke([Action]{ Enable-Buttons -Enable $Enable })
        } else {
            $script:BtnBackup.Enabled = $Enable
            $script:BtnRestore.Enabled = $Enable
        }
    }
}

# ============================================================
# 首次配置向导
# ============================================================
function Show-FirstRunConfig {
    $script:config = Load-Config
    
    # Use larger form and disable DPI scaling
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Hermes 同步 - 设置"
    $form.Size = New-Object System.Drawing.Size(540, 400)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Padding = New-Object System.Windows.Forms.Padding(10)
    $form.AutoScroll = $true
    
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "[设置] Hermes 同步工具"
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.Size = New-Object System.Drawing.Size(480, 30)
    $lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 255)
    $form.Controls.Add($lblTitle)
    
    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "请配置同步目录与本地路径。"
    $lblDesc.Location = New-Object System.Drawing.Point(20, 50)
    $lblDesc.Size = New-Object System.Drawing.Size(480, 20)
    $lblDesc.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblDesc)
    
    # Row 1: Sync Directory
    $lblSync = New-Object System.Windows.Forms.Label
    $lblSync.Text = "[目录] 同步目录（网盘 / U 盘）："
    $lblSync.Location = New-Object System.Drawing.Point(20, 85)
    $lblSync.Size = New-Object System.Drawing.Size(480, 20)
    $lblSync.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($lblSync)
    
    $txtSync = New-Object System.Windows.Forms.TextBox
    $txtSync.Text = $script:config.syncDir
    $txtSync.Location = New-Object System.Drawing.Point(20, 110)
    $txtSync.Size = New-Object System.Drawing.Size(400, 25)
    $txtSync.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtSync.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtSync)
    
    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = "浏览..."
    $btnSync.Location = New-Object System.Drawing.Point(430, 109)
    $btnSync.Size = New-Object System.Drawing.Size(70, 25)
    $btnSync.FlatStyle = "Flat"
    $btnSync.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSync.ForeColor = [System.Drawing.Color]::White
    $btnSync.Add_Click({
        $dir = New-Object System.Windows.Forms.FolderBrowserDialog
        $dir.Description = "请选择同步目录"
        if ($dir.ShowDialog() -eq "OK") { $txtSync.Text = $dir.SelectedPath }
    })
    $form.Controls.Add($btnSync)
    
    # Row 2: Hermes Data Directory
    $lblHermes = New-Object System.Windows.Forms.Label
    $lblHermes.Text = "[目录] Hermes 数据目录："
    $lblHermes.Location = New-Object System.Drawing.Point(20, 150)
    $lblHermes.Size = New-Object System.Drawing.Size(480, 20)
    $lblHermes.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($lblHermes)
    
    $txtHermes = New-Object System.Windows.Forms.TextBox
    $txtHermes.Text = $script:config.hermesDataDir
    $txtHermes.Location = New-Object System.Drawing.Point(20, 175)
    $txtHermes.Size = New-Object System.Drawing.Size(400, 25)
    $txtHermes.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtHermes.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtHermes)
    
    $btnHermes = New-Object System.Windows.Forms.Button
    $btnHermes.Text = "浏览..."
    $btnHermes.Location = New-Object System.Drawing.Point(430, 174)
    $btnHermes.Size = New-Object System.Drawing.Size(70, 25)
    $btnHermes.FlatStyle = "Flat"
    $btnHermes.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnHermes.ForeColor = [System.Drawing.Color]::White
    $btnHermes.Add_Click({
        $dir = New-Object System.Windows.Forms.FolderBrowserDialog
        $dir.Description = "请选择 Hermes 数据目录"
        if ($dir.ShowDialog() -eq "OK") { $txtHermes.Text = $dir.SelectedPath }
    })
    $form.Controls.Add($btnHermes)
    
    # Row 3: Workspace Directory
    $lblWs = New-Object System.Windows.Forms.Label
    $lblWs.Text = "[目录] 工作空间目录："
    $lblWs.Location = New-Object System.Drawing.Point(20, 215)
    $lblWs.Size = New-Object System.Drawing.Size(480, 20)
    $lblWs.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($lblWs)
    
    $txtWs = New-Object System.Windows.Forms.TextBox
    $txtWs.Text = $script:config.workspaceDir
    $txtWs.Location = New-Object System.Drawing.Point(20, 240)
    $txtWs.Size = New-Object System.Drawing.Size(400, 25)
    $txtWs.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtWs.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtWs)
    
    $btnWs = New-Object System.Windows.Forms.Button
    $btnWs.Text = "浏览..."
    $btnWs.Location = New-Object System.Drawing.Point(430, 239)
    $btnWs.Size = New-Object System.Drawing.Size(70, 25)
    $btnWs.FlatStyle = "Flat"
    $btnWs.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnWs.ForeColor = [System.Drawing.Color]::White
    $btnWs.Add_Click({
        $dir = New-Object System.Windows.Forms.FolderBrowserDialog
        $dir.Description = "请选择工作空间目录"
        if ($dir.ShowDialog() -eq "OK") { $txtWs.Text = $dir.SelectedPath }
    })
    $form.Controls.Add($btnWs)
    
    # Row 4: Backup Limit
    $lblLimit = New-Object System.Windows.Forms.Label
    $lblLimit.Text = "[数量] 本地备份保留份数："
    $lblLimit.Location = New-Object System.Drawing.Point(20, 280)
    $lblLimit.Size = New-Object System.Drawing.Size(220, 20)
    $lblLimit.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($lblLimit)
    
    $numLimit = New-Object System.Windows.Forms.NumericUpDown
    $numLimit.Location = New-Object System.Drawing.Point(240, 278)
    $numLimit.Size = New-Object System.Drawing.Size(60, 25)
    $numLimit.Minimum = 2
    $numLimit.Maximum = 20
    $numLimit.Value = $script:config.localBackupLimit
    $numLimit.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $numLimit.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($numLimit)
    
    # Save Button
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "[确定] 保存配置"
    $btnSave.Location = New-Object System.Drawing.Point(150, 325)
    $btnSave.Size = New-Object System.Drawing.Size(220, 35)
    $btnSave.FlatStyle = "Flat"
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11)
    $btnSave.Add_Click({
        if (-not $txtSync.Text -or -not (Test-Path $txtSync.Text)) {
            [System.Windows.Forms.MessageBox]::Show("请选择一个有效的同步目录。", "提示", "OK", "Warning")
            return
        }
        $script:config.syncDir = $txtSync.Text
        $script:config.hermesDataDir = $txtHermes.Text
        $script:config.workspaceDir = $txtWs.Text
        $script:config.localBackupLimit = [int]$numLimit.Value
        $script:config.firstRun = $false
        Save-Config $script:config
        $form.DialogResult = "OK"
        $form.Close()
    })
    $form.Controls.Add($btnSave)
    
    $result = $form.ShowDialog()
    return ($result -eq "OK")
}

# ============================================================
# 主界面
# ============================================================
function Show-MainForm {
    # 加载配置
    $script:config = Load-Config
    
    if ($script:config.firstRun -or -not $script:config.syncDir) {
        if (-not (Show-FirstRunConfig)) {
            [System.Windows.Forms.MessageBox]::Show("必须完成配置才能使用。", "退出", "OK", "Warning")
            return
        }
        $script:config = Load-Config
    }
    
    # 单实例检测
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $mutex.WaitOne(0)) {
        [System.Windows.Forms.MessageBox]::Show("同步工具已在运行。", "提示", "OK", "Information")
        return
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Hermes 一键同步"
    $form.Size = New-Object System.Drawing.Size(500, 540)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.Padding = New-Object System.Windows.Forms.Padding(12)
    $form.AutoScroll = $true
    
    # Title
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Hermes 一键同步"
    $lblTitle.Location = New-Object System.Drawing.Point(12, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(460, 35)
    $lblTitle.TextAlign = "MiddleCenter"
    $lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 255)
    $form.Controls.Add($lblTitle)
    
    # Status Label
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "  就绪"
    $lblStatus.Location = New-Object System.Drawing.Point(15, 55)
    $lblStatus.Size = New-Object System.Drawing.Size(455, 30)
    $lblStatus.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11)
    $lblStatus.ForeColor = [System.Drawing.Color]::White
    $lblStatus.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $lblStatus.Padding = New-Object System.Windows.Forms.Padding(5, 3, 0, 0)
    $form.Controls.Add($lblStatus)
    
    # Button Panel
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Location = New-Object System.Drawing.Point(15, 95)
    $btnPanel.Size = New-Object System.Drawing.Size(455, 100)
    $btnPanel.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 35)
    $btnPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $form.Controls.Add($btnPanel)
    
    $script:BtnBackup = New-Object System.Windows.Forms.Button
    $script:BtnBackup.Text = "[存] 备份本机"
    $script:BtnBackup.Location = New-Object System.Drawing.Point(15, 25)
    $script:BtnBackup.Size = New-Object System.Drawing.Size(190, 50)
    $script:BtnBackup.FlatStyle = "Flat"
    $script:BtnBackup.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $script:BtnBackup.ForeColor = [System.Drawing.Color]::White
    $script:BtnBackup.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
    $script:BtnBackup.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
    $script:BtnBackup.Add_Click({
        $result = [System.Windows.Forms.MessageBox]::Show(
            "即将备份以下目录：`n- Hermes 数据`n- 工作空间`n`n输出位置：$($script:config.syncDir)`n`n确认开始备份？",
            "备份确认", "YesNo", "Information")
        if ($result -eq "Yes") {
            Enable-Buttons $false
            Show-Log -Text "========== Backup Start ==========" -Color "Green"
            $script:backupResult = $null
            $script:backupResult = Start-BackupProcess -Config $script:config -StatusLabel $lblStatus -ProgressBar $progressBar
            Enable-Buttons $true
        }
    })
    $btnPanel.Controls.Add($script:BtnBackup)
    
    $script:BtnRestore = New-Object System.Windows.Forms.Button
    $script:BtnRestore.Text = "[取] 恢复数据"
    $script:BtnRestore.Location = New-Object System.Drawing.Point(240, 25)
    $script:BtnRestore.Size = New-Object System.Drawing.Size(190, 50)
    $script:BtnRestore.FlatStyle = "Flat"
    $script:BtnRestore.BackColor = [System.Drawing.Color]::FromArgb(0, 60, 120)
    $script:BtnRestore.ForeColor = [System.Drawing.Color]::White
    $script:BtnRestore.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
    $script:BtnRestore.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $script:BtnRestore.Add_Click({
        $backups = Get-ChildItem $script:config.syncDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if (-not $backups -or $backups.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("同步目录中未找到备份文件。", "无备份", "OK", "Warning")
            return
        }
        $latest = $backups[0]
        $result = [System.Windows.Forms.MessageBox]::Show(
            "将使用最新备份覆盖本机数据：`n文件：$($latest.Name)`n创建时间：$($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))`n大小：$(Format-Size $latest.Length)`n`n[警告] 此操作不可撤销！将先创建回滚快照。`n确认继续？",
            "恢复确认", "YesNo", "Warning")
        if ($result -eq "Yes") {
            Enable-Buttons $false
            Show-Log -Text "========== Restore Start ==========" -Color "Green"
            $script:restoreResult = $null
            $script:restoreResult = Start-RestoreProcess -Config $script:config -StatusLabel $lblStatus -ProgressBar $progressBar
            Enable-Buttons $true
        }
    })
    $btnPanel.Controls.Add($script:BtnRestore)
    
    # Progress Bar
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15, 210)
    $progressBar.Size = New-Object System.Drawing.Size(455, 25)
    $progressBar.Style = "Continuous"
    $progressBar.Value = 0
    $form.Controls.Add($progressBar)
    
    # Info Label
    $lblInfo = New-Object System.Windows.Forms.Label
    $lastBkTime = if ($script:config.lastBackupTime) { ([datetime]$script:config.lastBackupTime).ToString("yyyy-MM-dd HH:mm") } else { "无" }
    $localBackups = (Get-ChildItem $BackupDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Measure-Object).Count
    $localUsed = (Get-ChildItem $BackupDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    $lblInfo.Text = "最近备份: $lastBkTime | 本地备份: $localBackups/$($script:config.localBackupLimit) $(Format-Size $localUsed)"
    $lblInfo.Location = New-Object System.Drawing.Point(15, 240)
    $lblInfo.Size = New-Object System.Drawing.Size(455, 20)
    $lblInfo.ForeColor = [System.Drawing.Color]::Gray
    $lblInfo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $form.Controls.Add($lblInfo)
    
    # Log Label
    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = "[日志] 操作日志"
    $lblLogTitle.Location = New-Object System.Drawing.Point(15, 265)
    $lblLogTitle.Size = New-Object System.Drawing.Size(120, 20)
    $lblLogTitle.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblLogTitle)
    
    # Settings Button
    $btnSettings = New-Object System.Windows.Forms.Button
    $btnSettings.Text = "设置"
    $btnSettings.Location = New-Object System.Drawing.Point(420, 265)
    $btnSettings.Size = New-Object System.Drawing.Size(50, 23)
    $btnSettings.FlatStyle = "Flat"
    $btnSettings.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSettings.ForeColor = [System.Drawing.Color]::White
    $btnSettings.Add_Click({
        if (Show-FirstRunConfig) { $script:config = Load-Config }
    })
    $form.Controls.Add($btnSettings)
    
    # Log Text Box
    $script:LogTextBox = New-Object System.Windows.Forms.RichTextBox
    $script:LogTextBox.Location = New-Object System.Drawing.Point(15, 290)
    $script:LogTextBox.Size = New-Object System.Drawing.Size(455, 200)
    $script:LogTextBox.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $script:LogTextBox.ForeColor = [System.Drawing.Color]::White
    $script:LogTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:LogTextBox.ReadOnly = $true
    $script:LogTextBox.BorderStyle = "None"
    $script:LogTextBox.ScrollBars = "Vertical"
    $form.Controls.Add($script:LogTextBox)
    
    # Startup Log
    Write-SyncLog "Hermes 同步工具已启动" "INFO"
    Update-Status -Label $lblStatus -Text "就绪" -Color "White"
    Show-Log -Text "[$(Get-Date -Format 'HH:mm:ss')] Hermes 同步工具已启动" -Color "White"
    Show-Log -Text "[$(Get-Date -Format 'HH:mm:ss')] 同步目录：$($script:config.syncDir)" -Color "White"
    Show-Log -Text "[$(Get-Date -Format 'HH:mm:ss')] 配置已加载" -Color "Green"
    
    $form.ShowDialog() | Out-Null
    $mutex.ReleaseMutex()
}

# ============================================================
# 入口
# ============================================================
if (-not $TestMode) {
    Show-MainForm
}
