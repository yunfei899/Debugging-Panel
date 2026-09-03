[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [switch]$AllowHardware,
    [switch]$AllowProgramLoad
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot
$runtimeDirectory = [string]$settings.RuntimeDirectory
$currentSessionPath = Join-Path $runtimeDirectory 'current-session.json'
$buildScriptPath = Join-Path $PSScriptRoot 'BuildProject.ps1'
$startScriptPath = Join-Path $PSScriptRoot 'StartSharedDebug.ps1'
$sendCommandPath = Join-Path $PSScriptRoot 'SendSharedDebugCommand.ps1'
$downloadStatusPath = Join-Path $runtimeDirectory 'download-status.txt'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$operationMutex = $null
$operationLockTaken = $false
$operationOwnsStatus = $false

function Set-DownloadStatus([string]$Value) {
    New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
    [IO.File]::WriteAllText($downloadStatusPath, $Value, $utf8NoBom)
}

function Get-SessionProcess($Session) {
    if ($null -eq $Session -or -not $Session.ProcessId) { return $null }
    return Get-Process -Id ([int]$Session.ProcessId) -ErrorAction SilentlyContinue
}

function Get-SessionBreakpoints($Session) {
    $active = [ordered]@{}
    if ($null -eq $Session -or -not $Session.EventsPath -or -not (Test-Path -LiteralPath $Session.EventsPath -PathType Leaf)) {
        return @()
    }

    foreach ($line in @(Get-Content -LiteralPath $Session.EventsPath)) {
        if ($line -match 'BREAKPOINT_ADDED id=(\d+)\s+(.+)$') {
            $active[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match 'BREAKPOINT_REMOVED id=(\d+)') {
            $active.Remove($Matches[1])
        }
    }
    return @($active.Values)
}

function Get-SessionWatch($Session) {
    if ($null -ne $Session -and $Session.Watch) {
        return @($Session.Watch | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    return @($settings.DefaultWatch | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

try {
    if (-not $AllowHardware) {
        throw 'Build and download connects to XDS2xx. Re-run with -AllowHardware.'
    }
    if (-not $AllowProgramLoad) {
        throw 'Build and download writes target memory. Re-run with -AllowProgramLoad.'
    }

    $mutexInput = ([IO.Path]::GetFullPath($ProjectRoot)).ToLowerInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $mutexHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexInput)))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    $operationMutex = New-Object Threading.Mutex($false, "Local\XDS2xxBuildAndDownload_$mutexHash")
    try { $operationLockTaken = $operationMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $operationLockTaken = $true }
    if (-not $operationLockTaken) {
        throw 'Another build/download operation is already running for this project.'
    }

    $operationOwnsStatus = $true
    Set-DownloadStatus "BUILDING;started=$([DateTime]::Now.ToString('s'))"

    $buildProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScriptPath, '-ProjectRoot', $ProjectRoot) `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden -Wait -PassThru
    if ($buildProcess.ExitCode -ne 0) {
        throw "Build failed with exit code $($buildProcess.ExitCode). See $(Join-Path $runtimeDirectory 'build.log')."
    }

    $buildStatusPath = Join-Path $runtimeDirectory 'build-status.txt'
    $buildStatus = if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $buildStatusPath).Trim()
    }
    else { '' }
    if (-not $buildStatus.StartsWith('SUCCESS')) {
        throw "Build did not finish successfully: $buildStatus"
    }

    $requiredFiles = @(
        [string]$settings.TargetConfig,
        [string]$settings.Program,
        $startScriptPath,
        $sendCommandPath,
        (Join-Path ([string]$settings.CcsRoot) 'ccs_base\scripting\bin\dss.bat')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required download file does not exist: $requiredFile"
        }
    }

    $currentSession = $null
    if (Test-Path -LiteralPath $currentSessionPath -PathType Leaf) {
        try { $currentSession = Get-Content -Raw -LiteralPath $currentSessionPath | ConvertFrom-Json } catch { $currentSession = $null }
    }
    $breakpoints = Get-SessionBreakpoints $currentSession
    $watch = Get-SessionWatch $currentSession
    $oldProcess = Get-SessionProcess $currentSession

    if ($oldProcess) {
        Set-DownloadStatus "STOPPING_SESSION;pid=$($oldProcess.Id)"
        & $sendCommandPath -Command 'STOP' -ProjectRoot $ProjectRoot -WaitMs 0 | Out-Null
        $stopDeadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $oldProcess = Get-SessionProcess $currentSession
        } while ($oldProcess -and (Get-Date) -lt $stopDeadline)
        if ($oldProcess) {
            throw "The existing shared debug session did not stop within 20 seconds; program was not downloaded."
        }
    }

    $programName = [IO.Path]::GetFileName([string]$settings.Program)
    Set-DownloadStatus "DOWNLOADING;starting=$programName"
    $startParameters = @{
        AllowHardware = $true
        LoadProgram = $true
        AllowProgramLoad = $true
        NoPanel = $true
    }
    if ($breakpoints.Count -gt 0) { $startParameters.Breakpoint = $breakpoints }
    if ($watch.Count -gt 0) { $startParameters.Watch = $watch }
    & $startScriptPath @startParameters | Out-Null

    $newSession = $null
    $loadConfirmed = $false
    $loadDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $loadDeadline) {
        if (Test-Path -LiteralPath $currentSessionPath -PathType Leaf) {
            try { $newSession = Get-Content -Raw -LiteralPath $currentSessionPath | ConvertFrom-Json } catch { $newSession = $null }
        }
        if ($newSession -and (Test-Path -LiteralPath $newSession.EventsPath -PathType Leaf)) {
            $newEvents = @(Get-Content -LiteralPath $newSession.EventsPath)
            if ($newEvents | Where-Object { $_ -match '\tLOADPROGRAM OK ' }) {
                $loadConfirmed = $true
                break
            }
            $newStatus = if (Test-Path -LiteralPath $newSession.StatusPath -PathType Leaf) {
                (Get-Content -Raw -LiteralPath $newSession.StatusPath).Trim()
            }
            else { '' }
            if ($newStatus.StartsWith('ERROR') -or ($newStatus.StartsWith('STOPPED') -and -not (Get-SessionProcess $newSession))) {
                throw "Program download failed: $newStatus"
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $loadConfirmed) {
        throw 'Timed out waiting for LOADPROGRAM OK; check the new shared session event log.'
    }

    Set-DownloadStatus "SUCCESS;finished=$([DateTime]::Now.ToString('s'));session=$($newSession.SessionDirectory)"
}
catch {
    $message = $_.Exception.Message -replace '[\r\n;]+', ' '
    if ($operationOwnsStatus) {
        Set-DownloadStatus "FAILED;message=$message"
    }
    throw
}
finally {
    if ($operationLockTaken -and $null -ne $operationMutex) {
        try { $operationMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $operationMutex) { $operationMutex.Dispose() }
}
