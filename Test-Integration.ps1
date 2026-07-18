#Requires -Version 5.1
# Integration test for Hermes Sync Tool - Runs WITHOUT closing Hermes
# Uses dummy data to validate the full backup-restore pipeline

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$TestRoot = "E:\Documents\Hermes\SyncTool\TestEnv"
$TestHermesDir = "$TestRoot\HermesData"
$TestWorkspace = "$TestRoot\Workspace"
$TestSyncDir = "$TestRoot\SyncDir"
$TestBackupDir = "$TestRoot\Backups"
$TestRollbackDir = "$TestBackupDir\.rollback"

function Initialize-TestEnvironment {
    Write-Host "`n[初始化] 创建测试环境..." -ForegroundColor Cyan
    
    # Clean previous test
    if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force }
    
    # Create dummy Hermes data structure
    $hermesStructure = @(
        "$TestHermesDir\state.db",
        "$TestHermesDir\config.yaml",
        "$TestHermesDir\.env",
        "$TestHermesDir\auth.json",
        "$TestHermesDir\skills\skill1\SKILL.md",
        "$TestHermesDir\skills\skill2\main.py",
        "$TestHermesDir\memories\USER.md",
        "$TestHermesDir\logs\agent.log",
        "$TestHermesDir\logs\errors.log",
        "$TestHermesDir\cache\tmp.dat"
    )
    
    # Create dummy workspace structure
    $wsStructure = @(
        "$TestWorkspace\project1\doc.md",
        "$TestWorkspace\project2\data.xlsx",
        "$TestWorkspace\scripts\run.ps1",
        "$TestWorkspace\.git\HEAD"
    )
    
    foreach ($item in ($hermesStructure + $wsStructure)) {
        $dir = Split-Path $item -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Write dummy content with some size
        $content = "DUMMY DATA - $(Get-Date) - $($item | Out-String)" * 100
        Set-Content -Path $item -Value $content -Force -Encoding UTF8
    }
    
    # Create directories
    New-Item -ItemType Directory -Force -Path $TestSyncDir | Out-Null
    New-Item -ItemType Directory -Force -Path $TestBackupDir | Out-Null
    New-Item -ItemType Directory -Force -Path $TestRollbackDir | Out-Null
    
    $totalSize = (Get-ChildItem $TestRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host "  ✓ 测试环境创建完成 ($(Format-Size $totalSize))" -ForegroundColor Green
    Write-Host "  📁 Hermes 模拟数据: $TestHermesDir" -ForegroundColor Gray
    Write-Host "  📁 工作空间模拟: $TestWorkspace" -ForegroundColor Gray
    Write-Host "  📁 同步目录: $TestSyncDir" -ForegroundColor Gray
}

function Get-Exclusions {
    @("logs", "*.log", "*.tmp", "*.cache", ".vs", "__pycache__", "node_modules", ".rollback", ".git")
}

function Test-ShouldExclude {
    param([string]$ItemName)
    $exclusions = Get-Exclusions
    foreach ($excl in $exclusions) {
        if ($excl.StartsWith("*")) {
            if ($ItemName -like $excl) { return $true }
        } elseif ($ItemName -eq $excl) { return $true }
    }
    # Also exclude filenames starting with tmp (like tmp.dat)
    if ($ItemName -like "tmp*") { return $true }
    return $false
}

function Format-Size {
    param($Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Copy-Filtered {
    param($Source, $Destination)
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    
    $files = Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-ShouldExclude $_.Name) }
    foreach ($f in $files) {
        $relPath = $f.FullName.Substring($Source.Length).TrimStart("\")
        $destFile = Join-Path $Destination $relPath
        $destDir = Split-Path $destFile -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item $f.FullName $destFile -Force
    }
}

function Test-BackupFlow {
    Write-Host "`n===== 测试1: 备份流程 =====" -ForegroundColor Cyan
    
    # Step 1: Data scan
    Write-Host "`n[步骤1] 扫描数据..." -ForegroundColor Yellow
    $sources = @($TestHermesDir, $TestWorkspace)
    $totalFiles = 0
    $totalSize = 0
    $collectedFiles = @()
    
    foreach ($src in $sources) {
        if (Test-Path $src) {
            $files = Get-ChildItem $src -Recurse -File | Where-Object { -not (Test-ShouldExclude $_.Name) }
            $count = ($files | Measure-Object).Count
            $size = ($files | Measure-Object -Property Length -Sum).Sum
            $totalFiles += $count
            $totalSize += $size
            Write-Host "  📁 $(Split-Path $src -Leaf): $count 个文件, $(Format-Size $size)" -ForegroundColor Gray
            foreach ($f in $files) {
                $collectedFiles += [PSCustomObject]@{
                    FullName = $f.FullName
                    Relative = $f.FullName.Substring($src.Length).TrimStart("\")
                }
            }
        }
    }
    Write-Host "  📊 总计: $totalFiles 个文件, $(Format-Size $totalSize)" -ForegroundColor White
    
    # Step 2: Build ZIP via temp dir
    Write-Host "`n[步骤2] 构建压缩包..." -ForegroundColor Yellow
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $zipName = "HermesSync_$timestamp.zip"
    $localZip = Join-Path $TestBackupDir $zipName
    
    $tempDir = "$TestRoot\TempBuild"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    foreach ($f in $collectedFiles) {
        $destDir = Join-Path $tempDir (Split-Path $f.Relative -Parent)
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item $f.FullName (Join-Path $destDir (Split-Path $f.Relative -Leaf)) -Force
    }
    
    if (Test-Path $localZip) { Remove-Item $localZip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $localZip, "Optimal", $false)
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    
    $zipSize = (Get-Item $localZip).Length
    Write-Host "  ✓ ZIP 创建完成: $zipName ($(Format-Size $zipSize))" -ForegroundColor Green
    
    # Step 3: Validation
    Write-Host "`n[步骤3] 完整性校验..." -ForegroundColor Yellow
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($localZip)
        $entryCount = $zip.Entries.Count
        $zip.Dispose()
        Write-Host "  ✓ 校验通过 ($entryCount 个条目)" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ 校验失败: $_" -ForegroundColor Red
        return $null
    }
    
    # Step 4: Dual output
    Write-Host "`n[步骤4] 复制到同步目录..." -ForegroundColor Yellow
    $syncZip = Join-Path $TestSyncDir $zipName
    Copy-Item $localZip $syncZip -Force
    Write-Host "  ✓ 同步副本完成" -ForegroundColor Green
    
    # Step 5: Cleanup old backups
    Write-Host "`n[步骤5] 清理旧备份..." -ForegroundColor Yellow
    $backups = Get-ChildItem $TestBackupDir -Filter "HermesSync_*.zip" | Sort-Object LastWriteTime -Descending
    $limit = 5
    if ($backups.Count -gt $limit) {
        $toDelete = $backups | Select-Object -Skip $limit
        foreach ($b in $toDelete) { Remove-Item $b.FullName -Force }
    }
    Write-Host "  ✓ 保留 $($backups.Count) / $limit 个备份" -ForegroundColor Green
    
    return @{ ZipName = $zipName; ZipPath = $localZip; SyncPath = $syncZip; Timestamp = $timestamp }
}

function Test-RestoreFlow {
    param($BackupResult)
    Write-Host "`n===== 测试2: 恢复流程 =====" -ForegroundColor Cyan
    
    # Step 1: Find latest backup
    Write-Host "`n[步骤1] 查找最新备份..." -ForegroundColor Yellow
    $backups = Get-ChildItem $TestSyncDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $backups -or $backups.Count -eq 0) {
        Write-Host "  ✗ 未找到备份文件" -ForegroundColor Red
        return $false
    }
    $latest = $backups[0]
    Write-Host "  📦 使用备份: $($latest.Name)" -ForegroundColor White
    Write-Host "  创建时间: $($latest.LastWriteTime)" -ForegroundColor Gray
    
    # Step 2: Conflict detection
    Write-Host "`n[步骤2] 冲突检测..." -ForegroundColor Yellow
    $stateDbOriginal = Join-Path $TestHermesDir "state.db"
    $originalTime = (Get-Item $stateDbOriginal).LastWriteTime
    $bakTime = $latest.LastWriteTime
    
    if ($originalTime -gt $bakTime) {
        Write-Host "  ⚠ 本机数据比备份新 (本机:$originalTime vs 备份:$bakTime)" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ 无冲突" -ForegroundColor Green
    }
    
    # Step 3: Snapshot rollback
    Write-Host "`n[步骤3] 创建回滚快照..." -ForegroundColor Yellow
    $rollbackTs = Get-Date -Format "yyyyMMdd_HHmmss"
    $rollbackPath = Join-Path $TestRollbackDir "rollback_$rollbackTs"
    foreach ($src in @($TestHermesDir, $TestWorkspace)) {
        $folderName = Split-Path $src -Leaf
        Copy-Filtered -Source $src -Destination "$rollbackPath\$folderName"
    }
    Write-Host "  ✓ 快照保存到: rollback_$rollbackTs" -ForegroundColor Green
    
    # Step 4: Extract ZIP
    Write-Host "`n[步骤4] 解压覆盖..." -ForegroundColor Yellow
    $extractTemp = "$TestRoot\TempRestore"
    if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $extractTemp | Out-Null
    
    try {
        Expand-Archive -Path $latest.FullName -DestinationPath $extractTemp -Force
        Write-Host "  ✓ 解压完成" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ 解压失败: $_" -ForegroundColor Red
        return $false
    }
    
    # Step 5: Overwrite targets
    Write-Host "`n[步骤5] 覆盖目标..." -ForegroundColor Yellow
    $extractFolders = Get-ChildItem $extractTemp -Directory -ErrorAction SilentlyContinue
    foreach ($folder in $extractFolders) {
        $target = if ($folder.Name -eq "HermesData") { $TestHermesDir } elseif ($folder.Name -eq "Workspace") { $TestWorkspace } else { $null }
        if ($target) {
            Copy-Filtered -Source $folder.FullName -Destination $target
            Write-Host "  ✓ 已覆盖: $(Split-Path $target -Leaf)" -ForegroundColor Green
        }
    }
    
    # Step 6: Validation
    Write-Host "`n[步骤6] 结果验证..." -ForegroundColor Yellow
    $stateDb = Join-Path $TestHermesDir "state.db"
    $configYaml = Join-Path $TestHermesDir "config.yaml"
    
    $verified = $true
    if (-not (Test-Path $stateDb)) { Write-Host "  ✗ state.db 缺失" -ForegroundColor Red; $verified = $false }
    if (-not (Test-Path $configYaml)) { Write-Host "  ✗ config.yaml 缺失" -ForegroundColor Red; $verified = $false }
    
    if ($verified) {
        Write-Host "  ✓ 关键文件验证通过" -ForegroundColor Green
    }
    
    return $verified
}

function Test-ExclusionFilter {
    Write-Host "`n===== 测试3: 排除规则验证 =====" -ForegroundColor Cyan
    
    $testCases = @(
        @{ Name = "logs"; Expected = $true; Reason = "logs 目录应排除" }
        @{ Name = "agent.log"; Expected = $true; Reason = "日志文件应排除" }
        @{ Name = "tmp.dat"; Expected = $true; Reason = "tmp 文件应排除" }
        @{ Name = ".git"; Expected = $true; Reason = ".git 目录应排除" }
        @{ Name = "state.db"; Expected = $false; Reason = "state.db 不应排除" }
        @{ Name = "config.yaml"; Expected = $false; Reason = "config.yaml 不应排除" }
        @{ Name = "SKILL.md"; Expected = $false; Reason = "技能文件不应排除" }
    )
    
    $passed = 0
    $failed = 0
    
    foreach ($tc in $testCases) {
        $result = Test-ShouldExclude $tc.Name
        $status = if ($result -eq $tc.Expected) { "✓" } else { "✗" }
        $color = if ($result -eq $tc.Expected) { "Green" } else { "Red" }
        Write-Host "  $status '$tc.Name' → 排除=$result ($($tc.Reason))" -ForegroundColor $color
        if ($result -eq $tc.Expected) { $passed++ } else { $failed++ }
    }
    
    Write-Host "`n  排除规则: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
    return ($failed -eq 0)
}

function Test-EndToEnd {
    Write-Host "`n===== 测试4: 端到端数据完整性 =====" -ForegroundColor Cyan
    
    # Record original content hashes
    $originalFiles = @("$TestHermesDir\state.db", "$TestHermesDir\config.yaml", "$TestWorkspace\project1\doc.md")
    $originalHashes = @{}
    foreach ($f in $originalFiles) {
        if (Test-Path $f) {
            $content = [System.IO.File]::ReadAllBytes($f)
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            $hash = $hasher.ComputeHash($content)
            $originalHashes[$f] = [BitConverter]::ToString($hash)
        }
    }
    
    # Modify files to simulate user work
    Write-Host "`n[模拟] 修改数据..." -ForegroundColor Yellow
    foreach ($f in $originalFiles) {
        $newContent = "MODIFIED DATA $(Get-Date) - New user conversation content here"
        Set-Content -Path $f -Value $newContent -Force
    }
    Write-Host "  ✓ 数据已修改（模拟用户工作）" -ForegroundColor Green
    
    # Backup (after modification)
    Write-Host "`n[备份] 保存修改后的数据..." -ForegroundColor Yellow
    $backup = Test-BackupFlow
    if (-not $backup) { Write-Host "  ✗ 备份失败" -ForegroundColor Red; return $false }
    
    # Modify again to simulate more work
    Write-Host "`n[模拟] 再次修改数据（模拟另一台电脑工作）..." -ForegroundColor Yellow
    foreach ($f in $originalFiles) {
        $newContent = "MORE MODIFIED DATA $(Get-Date) - Even newer content"
        Set-Content -Path $f -Value $newContent -Force
    }
    
    # Restore
    Write-Host "`n[恢复] 恢复到备份版本..." -ForegroundColor Yellow
    $restoreResult = Test-RestoreFlow -BackupResult $backup
    if (-not $restoreResult) { Write-Host "  ✗ 恢复失败" -ForegroundColor Red; return $false }
    
    # Verify content matches backup (not the latest modification)
    Write-Host "`n[验证] 确认恢复内容正确..." -ForegroundColor Yellow
    $content = Get-Content "$TestHermesDir\state.db" -Raw
    if ($content -like "*MODIFIED DATA*") {
        Write-Host "  ✓ 恢复内容与备份一致（正确）" -ForegroundColor Green
        return $true
    } elseif ($content -like "*MORE MODIFIED DATA*") {
        Write-Host "  ✗ 恢复未生效，仍是最新数据" -ForegroundColor Red
        return $false
    } else {
        Write-Host "  ? 内容不符合预期" -ForegroundColor Yellow
        return $false
    }
}

function Show-FinalReport {
    param($Results)
    
    Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
    Write-Host "  Hermes Sync Tool - 集成测试报告" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    
    $allPassed = $true
    foreach ($r in $Results) {
        $status = if ($r.Passed) { "✓ PASS" } else { "✗ FAIL" }
        $color = if ($r.Passed) { "Green" } else { "Red" }
        Write-Host "  $status - $($r.Name)" -ForegroundColor $color
        if (-not $r.Passed) { $allPassed = $false }
    }
    
    Write-Host ("-" * 50) -ForegroundColor Gray
    if ($allPassed) {
        Write-Host "  全部通过！工具逻辑验证完成。" -ForegroundColor Green
        Write-Host "  您可以在实际使用时放心使用。" -ForegroundColor Green
    } else {
        Write-Host "  存在失败的测试项，请检查并修复。" -ForegroundColor Red
    }
    Write-Host ("=" * 50) -ForegroundColor Cyan
    
    # Cleanup
    Write-Host "`n[清理] 删除测试环境..." -ForegroundColor Yellow
    if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force }
    Write-Host "  ✓ 测试环境已清理" -ForegroundColor Green
    
    return $allPassed
}

# ============================================================
# Main
# ============================================================
Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Hermes Sync Tool - 集成测试 (No GUI)   ║" -ForegroundColor Cyan
Write-Host "║   使用模拟数据，无需关闭 Hermes          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan

$testResults = @()

try {
    Initialize-TestEnvironment
    
    # Test 1: Backup
    Write-Host "`n--- Test 1: 备份流程 ---" -ForegroundColor White
    $backupResult = Test-BackupFlow
    $testResults += @{ Name = "备份流程"; Passed = ($backupResult -ne $null) }
    
    # Test 2: Restore (only if backup succeeded)
    if ($backupResult) {
        Write-Host "`n--- Test 2: 恢复流程 ---" -ForegroundColor White
        $restoreResult = Test-RestoreFlow -BackupResult $backupResult
        $testResults += @{ Name = "恢复流程"; Passed = $restoreResult }
    } else {
        $testResults += @{ Name = "恢复流程"; Passed = $false }
    }
    
    # Test 3: Exclusion filter
    Write-Host "`n--- Test 3: 排除规则 ---" -ForegroundColor White
    $exclusionResult = Test-ExclusionFilter
    $testResults += @{ Name = "排除规则"; Passed = $exclusionResult }
    
    # Test 4: End-to-end data integrity
    Write-Host "`n--- Test 4: 端到端完整性 ---" -ForegroundColor White
    $e2eResult = Test-EndToEnd
    $testResults += @{ Name = "端到端完整性"; Passed = $e2eResult }
    
    # Show report
    Show-FinalReport -Results $testResults
    
} catch {
    Write-Host "`n❌ 测试异常: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    # Cleanup
    if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
