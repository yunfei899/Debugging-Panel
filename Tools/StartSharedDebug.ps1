[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ProjectFile,
    [string]$Program,
    [ValidateSet('JTAG', 'SWD')]
    [string]$Interface,
    [string]$Device,
    [string]$Cpu,
    [ValidateRange(1, 50000)]
    [int]$SpeedKHz,
    [string]$SerialNumber,
    [string[]]$Breakpoint,
    [string[]]$Watch,
    [switch]$LoadProgram,
    [switch]$RestartTarget,
    [switch]$ResumeTarget,
    [switch]$AllowHardware,
    [switch]$AllowProgramLoad,
    [switch]$AllowRun,
    [switch]$NoPanel
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot

if (-not $AllowHardware) {
    throw 'Starting a shared debug session connects to the J-Link target. Re-run with -AllowHardware.'
}
if ($LoadProgram -and -not $AllowProgramLoad) {
    throw 'Loading a program writes target memory. Re-run with -AllowProgramLoad.'
}
if ($RestartTarget -and -not $AllowRun) {
    throw 'RestartTarget runs the CPU. Re-run with -AllowRun.'
}
if ($ResumeTarget -and -not $AllowRun) {
    throw 'ResumeTarget runs the CPU. Re-run with -AllowRun.'
}

if ([string]::IsNullOrWhiteSpace($ProjectFile)) { $ProjectFile = [string]$settings.IarProject }
if ([string]::IsNullOrWhiteSpace($Program)) { $Program = [string]$settings.Program }
if ([string]::IsNullOrWhiteSpace($Interface)) { $Interface = [string]$settings.HardwareInterface }
if ([string]::IsNullOrWhiteSpace($Device)) { $Device = [string]$settings.JLinkDevice }
if ([string]::IsNullOrWhiteSpace($Cpu)) { $Cpu = [string]$settings.JLinkCpu }
if ($SpeedKHz -le 0) { $SpeedKHz = [int]$settings.JLinkSpeedKHz }
if ([string]::IsNullOrWhiteSpace($SerialNumber)) { $SerialNumber = [string]$settings.JLinkSerialNumber }
if ($null -eq $Breakpoint -or $Breakpoint.Count -eq 0) { $Breakpoint = @($settings.DefaultBreakpoint) }
if ($null -eq $Watch -or $Watch.Count -eq 0) { $Watch = @($settings.DefaultWatch) }

if (-not [IO.Path]::IsPathRooted($ProjectFile)) { $ProjectFile = Join-Path $ProjectRoot $ProjectFile }
if (-not [IO.Path]::IsPathRooted($Program)) { $Program = Join-Path $ProjectRoot $Program }
$ProjectFile = [IO.Path]::GetFullPath($ProjectFile)
$Program = [IO.Path]::GetFullPath($Program)

$debugRoot = [string]$settings.RuntimeDirectory
$currentSessionPath = Join-Path $debugRoot 'current-session.json'
$runnerPath = Join-Path $PSScriptRoot 'RunSharedDebug.ps1'
$backendPath = Join-Path $PSScriptRoot 'IarGdbSession.ps1'
$downloadScriptPath = Join-Path $PSScriptRoot 'IarCspyDownload.ps1'
$panelPath = Join-Path $PSScriptRoot 'SharedDebugPanel.ps1'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

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
    foreach ($directory in @(Get-ChildItem -LiteralPath $debugRoot -Directory -Filter 'Shared-*' -ErrorAction SilentlyContinue)) {
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

function Stop-StaleJLinkServers {
    $knownIds = @(Get-KnownJLinkProcessIds)
    foreach ($id in $knownIds) {
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -ine 'JLinkGDBServerCL') { continue }
        Write-Warning "Stopping stale project J-Link GDB Server PID $id."
        Stop-Process -Id $id -Force -ErrorAction Stop
    }

    $deadline = (Get-Date).AddSeconds(5)
    do {
        $owner = Get-ListeningProcessId
        if ($null -eq $owner) { return }
        if ($knownIds -notcontains $owner) {
            throw "J-Link server port $($settings.GdbServerPort) is occupied by $(Get-ProcessDescription $owner); close that external debugger before connecting."
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $owner = Get-ListeningProcessId
    if ($null -ne $owner) {
        throw "J-Link server port $($settings.GdbServerPort) is still occupied by $(Get-ProcessDescription $owner)."
    }
}

$requiredFiles = @(
    $ProjectFile,
    $Program,
    [string]$settings.Gdb,
    [string]$settings.JLinkGdbServer,
    $runnerPath,
    $backendPath
)
if ($LoadProgram) {
    $requiredFiles += @(
        $downloadScriptPath,
        [string]$settings.CspyBat,
        [string]$settings.CspyGeneralSettings,
        [string]$settings.CspyDriverSettings
    )
}
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required IAR shared debug file does not exist: $requiredFile"
    }
}

$driverText = Get-Content -Raw -LiteralPath ([string]$settings.CspyDriverSettings)
$driverInterface = if ($driverText -match '(?m)--drv_interface=([A-Za-z0-9_-]+)') { $Matches[1].ToUpperInvariant() } else { '' }
if ($driverInterface -and $driverInterface -ne $Interface.ToUpperInvariant()) {
    throw "Interface mismatch: SharedDebugConfig uses $Interface, but IAR driver settings use $driverInterface. Verify the physical connection and synchronize the settings before connecting."
}

$sourceFiles = @()
foreach ($sourceRoot in @($settings.SourceRoots)) {
    if (Test-Path -LiteralPath ([string]$sourceRoot) -PathType Container) {
        $sourceFiles += @(Get-ChildItem -LiteralPath ([string]$sourceRoot) -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.c', '.C', '.h', '.hpp', '.s', '.S') })
    }
}
$newestSource = $sourceFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$programInfo = Get-Item -LiteralPath $Program
if ($null -ne $newestSource -and $newestSource.LastWriteTime -gt $programInfo.LastWriteTime) {
    Write-Warning "Program symbols may be stale. Newest source: $($newestSource.FullName); program: $Program"
}

if (Test-Path -LiteralPath $currentSessionPath -PathType Leaf) {
    try {
$current = Get-Content -Raw -LiteralPath $currentSessionPath -Encoding UTF8 | ConvertFrom-Json
        if ($current.ProcessId) {
            $currentProcess = Get-Process -Id ([int]$current.ProcessId) -ErrorAction SilentlyContinue
            if ($currentProcess) {
                throw "A shared debug session is already running (PID $($current.ProcessId))."
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
        Write-Warning "Unable to parse the previous session file; a new session will be created: $($_.Exception.Message)"
    }
}

Stop-StaleJLinkServers

New-Item -ItemType Directory -Force -Path $debugRoot | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$sessionDirectory = Join-Path $debugRoot "Shared-$timestamp"
$commandDirectory = Join-Path $sessionDirectory 'commands'
New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null

$statusPath = Join-Path $sessionDirectory 'status.txt'
$eventsPath = Join-Path $sessionDirectory 'events.log'
$stdoutPath = Join-Path $sessionDirectory 'backend.stdout.log'
$stderrPath = Join-Path $sessionDirectory 'backend.stderr.log'
$jlinkStdoutPath = Join-Path $sessionDirectory 'jlink.stdout.log'
$jlinkStderrPath = Join-Path $sessionDirectory 'jlink.stderr.log'
$jlinkLogPath = Join-Path $sessionDirectory 'jlink.log'
$sessionPath = Join-Path $sessionDirectory 'session.json'

$jlinkArguments = @(
    '-nogui',
    '-nosinglerun',
    '-CPU', $Cpu,
    '-if', $Interface,
    '-speed', [string]$SpeedKHz,
    '-port', [string]$settings.GdbServerPort,
    '-LocalhostOnly'
)
if (-not [string]::IsNullOrWhiteSpace($Device)) {
    $jlinkArguments = @('-nogui', '-nosinglerun', '-device', $Device, '-if', $Interface,
        '-speed', [string]$SpeedKHz, '-port', [string]$settings.GdbServerPort, '-LocalhostOnly')
}
if (-not [string]::IsNullOrWhiteSpace($SerialNumber)) {
    $jlinkArguments += @('-select', "USB=$SerialNumber")
}
if (-not [string]::IsNullOrWhiteSpace([string]$settings.JLinkJtagConfig)) {
    $jlinkArguments += @('-jtagconf', [string]$settings.JLinkJtagConfig)
}

$session = [ordered]@{
    Version = 2
    Backend = 'JLinkGdbServer-GdbMi'
    ProcessId = $null
    Started = (Get-Date).ToString('o')
    ProjectRoot = $ProjectRoot
    SessionDirectory = $sessionDirectory
    CommandDirectory = $commandDirectory
    StatusPath = $statusPath
    EventsPath = $eventsPath
    BackendPath = $backendPath
    Program = (Resolve-Path -LiteralPath $Program).Path
    IarProject = (Resolve-Path -LiteralPath $ProjectFile).Path
    IarConfiguration = [string]$settings.IarConfiguration
    CspyDriverSettings = (Resolve-Path -LiteralPath ([string]$settings.CspyDriverSettings)).Path
    CspyMacroFile = (Resolve-Path -LiteralPath ([string]$settings.MacroFile)).Path
    Breakpoints = @($Breakpoint)
    Watch = @($Watch)
    LoadProgram = $false
    ProgramLoadedByCspy = $LoadProgram.IsPresent
    RestartTarget = $RestartTarget.IsPresent
    ResumeTarget = $ResumeTarget.IsPresent
    GdbPath = (Resolve-Path -LiteralPath ([string]$settings.Gdb)).Path
    GdbServerHost = [string]$settings.GdbServerHost
    GdbServerPort = [int]$settings.GdbServerPort
    JLinkGdbServerPath = (Resolve-Path -LiteralPath ([string]$settings.JLinkGdbServer)).Path
    JLinkArguments = $jlinkArguments
    JLinkStdoutPath = $jlinkStdoutPath
    JLinkStderrPath = $jlinkStderrPath
    JLinkLogPath = $jlinkLogPath
    TargetDevice = [string]$settings.TargetDevice
    JLinkDevice = $Device
    JLinkCpu = $Cpu
    HardwareInterface = $Interface
    JLinkSpeedKHz = $SpeedKHz
    JLinkSerialNumber = $SerialNumber
    JLinkJtagConfig = [string]$settings.JLinkJtagConfig
}

function Write-SessionJson {
    [IO.File]::WriteAllText($sessionPath, ($session | ConvertTo-Json -Depth 6), $utf8NoBom)
}

function Write-StatusFile([string]$Path, [string]$Value) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    [IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

try {
    Write-SessionJson

    if ($LoadProgram) {
        Write-StatusFile -Path $statusPath -Value 'CSPY_DOWNLOADING'
        & $downloadScriptPath `
            -ProjectRoot $ProjectRoot `
            -Program $Program `
            -EventsPath $eventsPath `
            -StatusPath (Join-Path $sessionDirectory 'cspy-download.status.txt') `
            -AllowHardware `
            -AllowProgramLoad
        [IO.File]::AppendAllText(
            $eventsPath,
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')`tLOADPROGRAM OK $Program$([Environment]::NewLine)",
            $utf8NoBom
        )
    }

    Write-SessionJson
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-SessionPath', $sessionPath) `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru
    $session.ProcessId = $process.Id
    Write-SessionJson
    [IO.File]::WriteAllText($currentSessionPath, ($session | ConvertTo-Json -Depth 6), $utf8NoBom)

    $deadline = (Get-Date).AddSeconds(35)
    $backendReady = $false
    while ((Get-Date) -lt $deadline) {
        $status = ''
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            $status = (Get-Content -Raw -LiteralPath $statusPath -Encoding UTF8).Trim()
            if ($status.StartsWith('ERROR')) {
                $detail = if ($status -match ';message=(.*)$') { $Matches[1] } else { $status }
                throw "Shared debug backend failed to start: $detail"
            }
            if ($status -match '^(RUNNING|HALTED|DISCONNECTED)') {
                $backendReady = $true
                break
            }
        }
        $process.Refresh()
        if ($process.HasExited) {
            $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $stderrPath -Encoding UTF8).Trim() } else { '' }
            $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { (Get-Content -Raw -LiteralPath $stdoutPath -Encoding UTF8).Trim() } else { '' }
            $detail = @($stderr, $stdout) | Where-Object { $_ } | Select-Object -First 1
            if ($status) {
                throw "Shared debug backend exited before becoming ready: $status"
            }
            if (-not $detail) { $detail = "backend exited with code $($process.ExitCode)." }
            throw $detail
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not $backendReady) {
        throw "Timed out waiting for the shared debug backend. See $stderrPath and $eventsPath."
    }
    $finalStatus = (Get-Content -Raw -LiteralPath $statusPath -Encoding UTF8).Trim()
    if ($finalStatus.StartsWith('ERROR')) { throw "Shared debug backend failed to start: $finalStatus" }

    if (-not $NoPanel) {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $panelPath, '-ProjectRoot', $ProjectRoot) |
            Out-Null
    }

    Write-Host "IAR/J-Link shared debug session started. PID: $($process.Id)"
    Write-Host "Session: $sessionPath"
    Write-Host "Status:  $statusPath"
}
catch {
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        [IO.File]::WriteAllText($statusPath, "ERROR;message=$message", $utf8NoBom)
    }
    throw
}
