<#
Wraps the Intel WPT/GPUView trace workflow described in gpu_view_wiki.txt:
  1. (Optional) Set DXVA driver-log registry keys
  2. Run the trace .cmd once       -> starts ETW capture
  3. Reproduce the issue
  4. Run the SAME trace .cmd again -> stops capture and writes Merged.etl
     (the tooling expects two runs, not Ctrl+C - see wiki note #73)

Usage:
  .\Capture-GpuViewTrace.ps1
  .\Capture-GpuViewTrace.ps1 -TraceScript "Trace-IntelMedia3DDisp+KmRTLog+HwSchedulingOn.cmd" -OutputDir C:\Traces
  .\Capture-GpuViewTrace.ps1 -IncludeDriverLog   # prompts for the DXVA instance index (e.g. 0000). This will install the reg keys

  .\Capture-GpuViewTrace.ps1 -ReinstallGfxEvents
      One-time prerequisite setup: runs uninstall.bat then Install.bat in
      C:\TestTools-Release-Internal-x64\GfxEvents, then prompts to reboot.
      Does ONLY this (no trace capture) - run it once, reboot, then re-run
      the script normally (without this switch) to capture a trace.
#>

[CmdletBinding()]
param(
    [string]$GpuViewDir = "C:\WPT\gpuview",

    [string]$TraceScript = "Trace-IntelMedia3DDisp+KmRTLog.cmd",

    [string]$OutputDir = "$env:USERPROFILE\Desktop\GpuViewTraces",

    [int]$MergeTimeoutSec = 180,

    # Only needed if you suspect a Media driver issue - adds Message/Tag dump keys under the
    # DXVA subkey, which makes the resulting ETL much larger.
    [switch]$IncludeDriverLog,

    [string]$GfxEventsDir = "C:\TestTools-Release-Internal-x64\GfxEvents",

    # Runs the GfxEvents uninstall/reinstall + reboot prerequisite and exits -
    # does not perform a trace capture. Use this by itself, reboot, then
    # re-run the script without this switch to actually capture a trace.
    [switch]$ReinstallGfxEvents
)

$ErrorActionPreference = "Stop"

$DxvaClassGuid = "{4d36e968-e325-11ce-bfc1-08002be10318}"
$DxvaValues = @{
    "Message Print Enabled" = 1
    "Message HLT Enabled"   = 1
    "Codec Message Tags"    = 7
    "VP Message Tags"       = 7
    "DDI Message Tags"      = 7
}

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "This script must be run from an elevated (Administrator) PowerShell prompt." -ForegroundColor Red
        exit 1
    }
}

# One-time prerequisite: reinstall the GfxEvents tooling and reboot. This is
# a standalone step - it does not capture a trace - so the caller exits right
# after this runs. Re-run the script without -ReinstallGfxEvents post-reboot.
function Invoke-GfxEventsReinstall {
    if (-not (Test-Path $GfxEventsDir)) {
        throw "GfxEvents directory not found: $GfxEventsDir. Check -GfxEventsDir."
    }

    foreach ($batName in @("uninstall.bat", "Install.bat")) {
        $batPath = Join-Path $GfxEventsDir $batName
        if (-not (Test-Path $batPath)) {
            throw "Expected script not found: $batPath"
        }

        Write-Host "`nRunning '$batName' in $GfxEventsDir ..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$batName`"" `
            -WorkingDirectory $GfxEventsDir -PassThru -Wait -WindowStyle Normal
        if ($proc.ExitCode -ne 0) {
            Write-Host "Warning: $batName exited with code $($proc.ExitCode)." -ForegroundColor Yellow
        }
    }

    Write-Host "`nGfxEvents uninstall/install complete. A reboot is required before capturing a trace." -ForegroundColor Yellow
    $rebootInput = Read-Host "Reboot now? (Y/N)"
    if ($rebootInput -match '^(y|yes)$') {
        Write-Host "Rebooting now ..." -ForegroundColor Cyan
        Restart-Computer -Force
    } else {
        Write-Host "Reboot manually, then re-run this script WITHOUT -ReinstallGfxEvents to capture a trace." -ForegroundColor Yellow
    }
}

# The trace .cmd remembers START vs STOP via the %TLOG% environment variable,
# which only lives inside a single cmd.exe process. Launching a new cmd.exe
# per call (as Start-Process "/c ..." does) loses that state, so the "STOP"
# call would always see a blank %TLOG% and re-run the START branch instead.
# Keep one interactive cmd.exe alive for the whole capture and feed it both
# commands via stdin so %TLOG% persists between START and STOP.
function Start-TraceConsole {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.WorkingDirectory = $GpuViewDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.AutoFlush = $true
    return $proc
}

function Send-TraceCommand([System.Diagnostics.Process]$CmdProc, [string]$Reason) {
    $outLog = Join-Path $GpuViewDir "TraceLog_$Reason.out.txt"
    $errLog = Join-Path $GpuViewDir "TraceLog_$Reason.err.txt"
    Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

    Write-Host "`n[$Reason] Sending '$TraceScript' to the trace console ..." -ForegroundColor Cyan
    $CmdProc.StandardInput.WriteLine("`"$TraceScript`" > `"$outLog`" 2>`"$errLog`"")
}

# Test-Path alone isn't enough: xperf creates Merged.etl before it finishes
# writing/merging into it, so a bare existence check races with xperf still
# holding the file open. Poll for an exclusive-read open to succeed instead,
# which only works once xperf has actually closed the file.
function Wait-FileUnlocked([string]$Path, [int]$TimeoutSec) {
    $waited = 0
    while ($waited -lt $TimeoutSec) {
        if (Test-Path $Path) {
            try {
                $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                $stream.Close()
                return $true
            } catch [System.IO.IOException] {
                # still locked by the merge process - keep waiting
            }
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    return $false
}

function Show-TraceLog([string]$Reason) {
    foreach ($suffix in @("out", "err")) {
        $log = Join-Path $GpuViewDir "TraceLog_$Reason.$suffix.txt"
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) {
            Write-Host "--- Last 20 lines of ${log}: ---" -ForegroundColor DarkGray
            Get-Content $log -Tail 20 | ForEach-Object { Write-Host $_ }
        }
    }
}

# Sets the DXVA dump keys at $DxvaPath and returns a hashtable of their prior values
# (null for a name that didn't exist) so they can be restored afterwards.
function Set-DxvaDriverLog([string]$DxvaPath) {
    if (-not (Test-Path $DxvaPath)) {
        New-Item -Path $DxvaPath -Force | Out-Null
    }
    $previous = @{}
    foreach ($name in $DxvaValues.Keys) {
        $existing = Get-ItemProperty -Path $DxvaPath -Name $name -ErrorAction SilentlyContinue
        $previous[$name] = if ($existing) { $existing.$name } else { $null }
        New-ItemProperty -Path $DxvaPath -Name $name -PropertyType DWord -Value $DxvaValues[$name] -Force | Out-Null
    }
    return $previous
}

function Restore-DxvaDriverLog([string]$DxvaPath, [hashtable]$Previous) {
    foreach ($name in $Previous.Keys) {
        if ($null -eq $Previous[$name]) {
            Remove-ItemProperty -Path $DxvaPath -Name $name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $DxvaPath -Name $name -Value $Previous[$name] -Force
        }
    }
}

# A crashed/aborted previous run (e.g. Ctrl+C instead of the expected second
# trace-script run) leaves these ETW sessions active, which makes the next
# START fail with "Cannot create a file when that file already exists" /
# "Invalid flags". Stop them first so a fresh capture can start cleanly.
function Stop-StaleTraceSessions {
    $sessionNames = @(
        "NT Kernel Logger", "CaptureState", "SchedulingLog", "NoCaptureState",
        "IntelMediaTrace", "D3D10Trace", "GfxTrace"
    )
    foreach ($name in $sessionNames) {
        & logman stop $name -ets *> $null
    }
}

Assert-Admin

if ($ReinstallGfxEvents) {
    Invoke-GfxEventsReinstall
    exit 0
}

$traceScriptPath = Join-Path $GpuViewDir $TraceScript
if (-not (Test-Path $traceScriptPath)) {
    throw "Trace script not found: $traceScriptPath. Check -GpuViewDir / -TraceScript."
}

$mergedEtlPath = Join-Path $GpuViewDir "Merged.etl"
if (Test-Path $mergedEtlPath) {
    Remove-Item $mergedEtlPath -Force
}

$dxvaPath = $null
$dxvaPrevious = $null

if ($IncludeDriverLog) {
    $defaultIndex = "0000"
    $indexInput = Read-Host "Enter the DXVA device instance index under Class GUID $DxvaClassGuid (see 'How to get the right DXVA registry key path'; ENTER for default '$defaultIndex')"
    if ([string]::IsNullOrWhiteSpace($indexInput)) { $indexInput = $defaultIndex }

    $classInstancePath = "HKLM:\SYSTEM\ControlSet001\Control\Class\$DxvaClassGuid\$indexInput"
    if (-not (Test-Path $classInstancePath)) {
        throw "No device instance found at $classInstancePath. Confirm the index per 'How to get the right DXVA registry key path'."
    }

    $dxvaPath = Join-Path $classInstancePath "DXVA"
    Write-Host "Setting DXVA driver log registry keys at $dxvaPath ..." -ForegroundColor Cyan
    $dxvaPrevious = Set-DxvaDriverLog -DxvaPath $dxvaPath
    Write-Host "Driver log keys set. Note: this makes the ETL file much bigger." -ForegroundColor Yellow
}

$cmdProc = $null

try {
    # --- Start capture ---
    Stop-StaleTraceSessions
    $cmdProc = Start-TraceConsole
    Send-TraceCommand -CmdProc $cmdProc -Reason "START"
    Start-Sleep -Seconds 2
    Show-TraceLog -Reason "START"

    Write-Host "`nTrace capture is running." -ForegroundColor Green
    Write-Host "Now reproduce the issue in your application."
    Write-Host "When you are done, press ENTER here to stop the trace and generate Merged.etl." -ForegroundColor Yellow
    Write-Host "(Type 'q' + ENTER instead to abort without collecting.)"

    $userInput = Read-Host
    if ($userInput -match '^(q|quit|abort)$') {
        Write-Host "Aborting without stopping/collecting trace. The capture cmd window may still be running." -ForegroundColor Yellow
        exit 0
    }

    # --- Stop capture / merge (same console, so %TLOG% is still set) ---
    Send-TraceCommand -CmdProc $cmdProc -Reason "STOP"

    Write-Host "`nWaiting for Merged.etl to be written..." -ForegroundColor Cyan
    $mergedReady = Wait-FileUnlocked -Path $mergedEtlPath -TimeoutSec $MergeTimeoutSec

    Show-TraceLog -Reason "STOP"

    if (-not $mergedReady) {
        throw "Merged.etl did not finish being written after $MergeTimeoutSec seconds. Check the trace cmd window for errors."
    }

    # --- Package result ---
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $zipPath = Join-Path $OutputDir "GpuViewTrace_$timestamp.zip"

    $maxZipAttempts = 3
    for ($attempt = 1; $attempt -le $maxZipAttempts; $attempt++) {
        try {
            Compress-Archive -Path $mergedEtlPath -DestinationPath $zipPath -Force
            break
        } catch {
            if ($attempt -eq $maxZipAttempts) { throw }
            Write-Host "Merged.etl still locked, retrying zip in 3s... ($attempt/$maxZipAttempts)" -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }

    Write-Host "`nDone. Trace saved to: $zipPath" -ForegroundColor Green
}
finally {
    if ($dxvaPath -and $dxvaPrevious) {
        Write-Host "`nRestoring previous DXVA registry values at $dxvaPath ..." -ForegroundColor Cyan
        Restore-DxvaDriverLog -DxvaPath $dxvaPath -Previous $dxvaPrevious
    }
    if ($cmdProc -and -not $cmdProc.HasExited) {
        $cmdProc.StandardInput.WriteLine("exit")
        $cmdProc.WaitForExit(5000) | Out-Null
    }
}
