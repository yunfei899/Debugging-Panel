[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [switch]$AllowHardware,
    [switch]$AllowProgramLoad
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if (-not $AllowHardware) {
    throw 'Build and download connects to the J-Link target. Re-run with -AllowHardware.'
}
if (-not $AllowProgramLoad) {
    throw 'Build and download writes target memory. Re-run with -AllowProgramLoad.'
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

function Read-SessionFile {
    if (-not (Test-Path -LiteralPath $currentSessionPath -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $currentSessionPath -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Get-SessionBreakpoints($Session) {
    $active = [ordered]@{}
    if ($null -eq $Session -or -not $Session.EventsPath -or -not (Test-Path -LiteralPath $Session.EventsPath -PathType Leaf)) {
        return @()
    }
    foreach ($line in @(Get-Content -LiteralPath $Session.EventsPath -Encoding UTF8)) {
        if ($line -match 'BREAKPOINT_ADDED id=([^\s]+)\s+(.+)$') {
            $active[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match 'BREAKPOINT_REMOVED id=([^\s]+)') {
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

function Get-ListeningProcessId {
    try {
        $connection = @(
            Get-NetTCPConnection -State Listen -LocalPort ([int]$settings.GdbServerPort) -ErrorAction Stop |
                Where-Object { $_.LocalAddress -in @('0.0.0.0', '127.0.0.1', '::', '::1') } |
                Select-Object -First 1
        )
        if ($connection.Count -eq 0) { return $null }
        return [int]$connection[0].OwningProcess
    }
    catch {
        return $null
    }
}

function Get-ProcessDescription([int]$ProcessId) {
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($process) { return "$($process.Name) (PID $ProcessId)" }
    }
    catch {}
    return "PID $ProcessId"
}

function Get-KnownJLinkProcessIds {
    $ids = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $runtimeDirectory -Directory -Filter 'Shared-*' -ErrorAction SilentlyContinue)) {
        $statusPath = Join-Path $directory.FullName 'status.txt'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { continue }
        $status = Get-Content -Raw -LiteralPath $statusPath -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($status -match 'jlinkPid=(\d+)') {
            $id = [int]$Matches[1]
            if ($ids -notcontains $id) { $ids += $id }
        }
    }
    return $ids
}

function Stop-OrphanedJLinkServers {
    $knownIds = @(Get-KnownJLinkProcessIds)
    foreach ($id in $knownIds) {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -ine 'JLinkGDBServerCL') { continue }
        Set-DownloadStatus "STOPPING_SESSION;jlinkPid=$id"
        Stop-Process -Id $id -Force -ErrorAction Stop
    }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        $owner = Get-ListeningProcessId
        if ($null -eq $owner) { return }
        if ($knownIds -notcontains $owner) {
            throw "J-Link server port $($settings.GdbServerPort) is occupied by $(Get-ProcessDescription $owner); close that external debugger before downloading."
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $owner = Get-ListeningProcessId
    if ($null -ne $owner) {
        throw "J-Link server port $($settings.GdbServerPort) is still occupied by $(Get-ProcessDescription $owner)."
    }
}

try {
    $mutexInput = $ProjectRoot.ToLowerInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $mutexHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexInput)))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    $operationMutex = New-Object Threading.Mutex($false, "Local\IarGdbBuildAndDownload_$mutexHash")
    try { $operationLockTaken = $operationMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $operationLockTaken = $true }
    if (-not $operationLockTaken) {
        throw 'Another build/download operation is already running for this project.'
    }
    $operationOwnsStatus = $true

    Set-DownloadStatus "BUILDING;started=$([DateTime]::Now.ToString('s'))"
    $buildProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScriptPath, '-ProjectRoot', $ProjectRoot) `
        -WorkingDirectory $ProjectRoot -WindowStyle Hidden -Wait -PassThru
    if ($buildProcess.ExitCode -ne 0) {
        throw "IAR build failed with exit code $($buildProcess.ExitCode). See $(Join-Path $runtimeDirectory 'build.log')."
    }

    $buildStatusPath = Join-Path $runtimeDirectory 'build-status.txt'
    $buildStatus = if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $buildStatusPath -Encoding UTF8).Trim()
    }
    else { '' }
    if (-not $buildStatus.StartsWith('SUCCESS')) {
        throw "IAR build did not finish successfully: $buildStatus"
    }

    foreach ($requiredFile in @($startScriptPath, $sendCommandPath, [string]$settings.Program)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required IAR download file does not exist: $requiredFile"
        }
    }

    $oldSession = Read-SessionFile
    $breakpoints = Get-SessionBreakpoints $oldSession
    $watch = Get-SessionWatch $oldSession
    $oldProcess = Get-SessionProcess $oldSession
    if ($oldProcess) {
        Set-DownloadStatus "STOPPING_SESSION;pid=$($oldProcess.Id)"
        & $sendCommandPath -Command 'STOP' -ProjectRoot $ProjectRoot -WaitMs 0 | Out-Null
        $stopDeadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $oldProcess = Get-SessionProcess $oldSession
        } while ($oldProcess -and (Get-Date) -lt $stopDeadline)
        if ($oldProcess) {
            throw 'The existing shared debug session did not stop within 20 seconds; the program was not downloaded.'
        }
    }

    Stop-OrphanedJLinkServers

    $programName = [IO.Path]::GetFileName([string]$settings.Program)
    Set-DownloadStatus "DOWNLOADING;program=$programName"
    $startParameters = @{
        ProjectRoot = $ProjectRoot
        AllowHardware = $true
        LoadProgram = $true
        AllowProgramLoad = $true
        ResumeTarget = [bool]$settings.IarBreakResetGo
        AllowRun = [bool]$settings.IarBreakResetGo
        NoPanel = $true
    }
    if ($breakpoints.Count -gt 0) { $startParameters.Breakpoint = $breakpoints }
    if ($watch.Count -gt 0) { $startParameters.Watch = $watch }
    & $startScriptPath @startParameters | Out-Null

    $newSession = $null
    $loadConfirmed = $false
    $loadDeadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $loadDeadline) {
        $newSession = Read-SessionFile
        if ($newSession -and (Test-Path -LiteralPath $newSession.EventsPath -PathType Leaf)) {
            $newEvents = @(Get-Content -LiteralPath $newSession.EventsPath -Encoding UTF8)
            if ($newEvents | Where-Object { $_ -match '\tLOADPROGRAM OK ' }) {
                $loadConfirmed = $true
                break
            }
            $newStatus = if (Test-Path -LiteralPath $newSession.StatusPath -PathType Leaf) {
                (Get-Content -Raw -LiteralPath $newSession.StatusPath -Encoding UTF8).Trim()
            }
            else { '' }
            if ($newStatus.StartsWith('ERROR')) {
                throw "Program download failed: $newStatus"
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $loadConfirmed) {
        throw 'Timed out waiting for IAR C-SPY LOADPROGRAM OK; check the shared session event log.'
    }

    Set-DownloadStatus "SUCCESS;finished=$([DateTime]::Now.ToString('s'));session=$($newSession.SessionDirectory)"
}
catch {
    $message = $_.Exception.Message -replace '[\r\n;]+', ' '
    if ($operationOwnsStatus) { Set-DownloadStatus "FAILED;message=$message" }
    throw
}
finally {
    if ($operationLockTaken -and $null -ne $operationMutex) {
        try { $operationMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $operationMutex) { $operationMutex.Dispose() }
}
