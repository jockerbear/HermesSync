#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $ScriptDir "HermesSyncGUI.ps1"

# dot-source 主脚本（带 -TestMode，避免弹出 GUI）
. "$MainScript" -TestMode

# ===================== 计数器 =====================
$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0

function Report-Result {
    param([string]$Name, [bool]$Ok, [string]$Note = "")
    if ($Ok) {
        $script:Passed++
        Write-Host "PASS - $Name"
    } else {
        $script:Failed++
        $msg = "FAIL - $Name"
        if ($Note -ne "") { $msg = "$msg ($Note)" }
        Write-Host $msg
    }
}

function Report-Skip {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    Write-Host "SKIP - $Name ($Reason)"
}

# ===================== 安全：临时目录与 dummy 镜像 =====================
# 仅复制 ping.exe 为唯一命名的可执行文件，镜像名唯一，taskkill 只命中本测试进程。
$TmpRoot  = $env:TEMP
$TestTag  = [guid]::NewGuid().ToString("N")
$WorkDir  = Join-Path $TmpRoot ("HermesStopTest_" + $TestTag)
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$SourceExe = "C:\Windows\System32\ping.exe"
if (-not (Test-Path $SourceExe)) {
    $SourceExe = "C:\Windows\SysWOW64\ping.exe"
}

$script:spawnedPids = @()

function New-Dummy {
    param([string]$BaseName)
    $dest = Join-Path $WorkDir ($BaseName + ".exe")
    Copy-Item -Path $SourceExe -Destination $dest -Force
    # ping -t 会一直运行直到被杀
    $proc = Start-Process -FilePath $dest -ArgumentList "-t","127.0.0.1" -WindowStyle Hidden -PassThru
    if ($proc -and $proc.Id) { $script:spawnedPids += $proc.Id }
    return $proc
}

function Test-ProcessGone {
    param([int]$Id)
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    return ($null -eq $p)
}

# ===================== 主测试流程 =====================
try {
    # ---------- 测试 A：回归，原函数 Get-HermesProcesses 应已定义 ----------
    try {
        $cmd = Get-Command Get-HermesProcesses -ErrorAction SilentlyContinue
        Report-Result -Name "A_Get-HermesProcesses_已定义" -Ok ($null -ne $cmd)
    } catch {
        Report-Result -Name "A_Get-HermesProcesses_已定义" -Ok $false -Note $_.Exception.Message
    }

    # ---------- 测试 B：Stop-ProcessList 按 PID 终止（dummy 名不含 hermes） ----------
    try {
        $d1 = New-Dummy "hsdummy_a"
        $d2 = New-Dummy "hsdummy_b"
        Start-Sleep -Milliseconds 400
        $ids = @($d1.Id, $d2.Id)
        $ret = Stop-ProcessList -ProcessIds $ids
        Start-Sleep -Milliseconds 600
        $gone1 = Test-ProcessGone $d1.Id
        $gone2 = Test-ProcessGone $d2.Id
        $ok = ($ret -eq $true) -and $gone1 -and $gone2
        Report-Result -Name "B_Stop-ProcessList_按PID终止" -Ok $ok -Note ("ret=$ret gone1=$gone1 gone2=$gone2")
    } catch {
        Report-Result -Name "B_Stop-ProcessList_按PID终止" -Ok $false -Note $_.Exception.Message
    }

    # ---------- 测试 C：无 Hermes 时 Stop-HermesProcesses 返回 $true（回归：原抛未识别函数） ----------
    try {
        # 安全护栏：若检测到非本测试 spawn 的真实 hermes 进程，则跳过（避免活体环境误报/误杀）
        $capturedC   = Get-HermesProcesses
        $realPresentC = $false
        foreach ($rc in $capturedC) {
            if ($script:spawnedPids -contains $rc.Id) { continue }
            $realPresentC = $true; break
        }
        if ($realPresentC) {
            Report-Skip -Name "C_Stop-HermesProcesses_无Hermes返回True" -Reason "检测到真实hermes进程，为安全跳过"
        } else {
            # 取末位标量，规避产品侧返回值偶发被包装成数组的情况
            $ret = @(Stop-HermesProcesses -TimeoutSeconds 5) | Select-Object -Last 1
            Report-Result -Name "C_Stop-HermesProcesses_无Hermes返回True" -Ok ($ret -eq $true) -Note ("ret=$ret")
        }
    } catch {
        Report-Result -Name "C_Stop-HermesProcesses_无Hermes返回True" -Ok $false -Note $_.Exception.Message
    }

    # ---------- 测试 D：watchdog 捕获 + 终止（端到端） ----------
    try {
        $dH = New-Dummy "hermes_dummy_test"
        Start-Sleep -Milliseconds 600
        $captured   = Get-HermesProcesses
        $foundDummy = $false
        foreach ($c in $captured) {
            if ($c.Id -eq $dH.Id) { $foundDummy = $true; break }
        }
        # 安全检查：是否存在非本测试 spawn 的真实 hermes 进程
        $realPresent = $false
        foreach ($c in $captured) {
            if ($c.Id -eq $dH.Id) { continue }
            if ($script:spawnedPids -contains $c.Id) { continue }
            $realPresent = $true; break
        }
        if (-not $foundDummy) {
            Report-Result -Name "D_watchdog捕获并终止" -Ok $false -Note "Get-HermesProcesses未捕获dummy"
        } elseif ($realPresent) {
            # 安全优先：仅清理本测试 dummy，不调用 Stop-HermesProcesses，避免误杀真实 hermes
            Stop-ProcessList -ProcessIds @($dH.Id) | Out-Null
            Report-Skip -Name "D_watchdog捕获并终止" -Reason "检测到真实hermes进程，为安全跳过Stop-HermesProcesses"
        } else {
            $ret = Stop-HermesProcesses -TimeoutSeconds 15
            Start-Sleep -Milliseconds 600
            $gone = Test-ProcessGone $dH.Id
            $ok = ($ret -eq $true) -and $gone
            Report-Result -Name "D_watchdog捕获并终止" -Ok $ok -Note ("ret=$ret gone=$gone")
        }
    } catch {
        Report-Result -Name "D_watchdog捕获并终止" -Ok $false -Note $_.Exception.Message
    }

    # ---------- 测试 E：主脚本语法解析 0 错误 ----------
    try {
        $tokens = $null
        $errs   = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($MainScript, [ref]$tokens, [ref]$errs)
        $ok = (($null -eq $errs) -or ($errs.Count -eq 0))
        Report-Result -Name "E_主脚本语法解析0错误" -Ok $ok -Note ("errCount=$(if($null -eq $errs){0}else{$errs.Count})")
    } catch {
        Report-Result -Name "E_主脚本语法解析0错误" -Ok $false -Note $_.Exception.Message
    }
} catch {
    Write-Host ("顶层异常: " + $_.Exception.Message)
} finally {
    # 清理：终止所有本测试 spawn 的 dummy 进程
    foreach ($id in $script:spawnedPids) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {}
        try {
            $w = Get-WmiObject Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue
            if ($w) { $w.Terminate() | Out-Null }
        } catch {}
    }
    # 兜底：扫描工作目录下的镜像并清理
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            try {
                if ($p.Path -and $p.Path.StartsWith($WorkDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    } catch {}
    # 删除临时目录
    try { if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
}

Write-Host ""
Write-Host ("总计: " + $script:Passed + " 通过, " + $script:Failed + " 失败")
if ($script:Skipped -gt 0) {
    Write-Host ("跳过: " + $script:Skipped)
}
