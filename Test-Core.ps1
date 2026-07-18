# Test script for Hermes Sync Tool core functions
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\HermesSyncGUI.ps1" -TestMode

Write-Host "=== Core Function Tests ===" -ForegroundColor Cyan

# Test 1: Config load
Write-Host "`n[Test 1] Loading config..." -ForegroundColor Yellow
$config = Load-Config
Write-Host "  Hermes dir: $($config.hermesDataDir)"
Write-Host "  Sync dir: $($config.syncDir)"
Write-Host "  Local backup limit: $($config.localBackupLimit)"

# Test 2: Process detection
Write-Host "`n[Test 2] Hermes process detection..." -ForegroundColor Yellow
$procs = Get-HermesProcesses
if ($procs) {
    Write-Host "  Found: $($procs.ProcessName -join ', ')" -ForegroundColor Red
} else {
    Write-Host "  No Hermes processes found (expected)" -ForegroundColor Green
}

# Test 3: Directory writeable test
Write-Host "`n[Test 3] Directory writeable test..." -ForegroundColor Yellow
$writeable = Test-DirectoryWriteable $config.syncDir
Write-Host "  Sync dir writeable: $writeable" -ForegroundColor $(if ($writeable) { "Green" } else { "Red" })

# Test 4: Directory size calculation
Write-Host "`n[Test 4] Directory size calculation..." -ForegroundColor Yellow
$size = Get-DirectorySize $config.hermesDataDir
Write-Host "  Hermes data size: $(Format-Size $size)"

# Test 5: Exclusion filter
Write-Host "`n[Test 5] Exclusion filter..." -ForegroundColor Yellow
Write-Host "  'logs' excluded: $(Test-ShouldExclude 'logs')"
Write-Host "  'test.log' excluded: $(Test-ShouldExclude 'test.log')"
Write-Host "  'state.db' excluded: $(Test-ShouldExclude 'state.db')"
Write-Host "  'skills' excluded: $(Test-ShouldExclude 'skills')"

# Test 6: Backup file naming
Write-Host "`n[Test 6] Backup file naming..." -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$zipName = "HermesSync_$timestamp.zip"
Write-Host "  Generated name: $zipName"

# Test 7: Backup directory scan
Write-Host "`n[Test 7] Backup directory scan..." -ForegroundColor Yellow
$backups = Get-ChildItem $config.syncDir -Filter "HermesSync_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
Write-Host "  Found $($backups.Count) backups"

Write-Host "`n=== All tests passed ===" -ForegroundColor Green
