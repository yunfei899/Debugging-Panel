[CmdletBinding()]
param(
    [string]$CcsRoot,
    [string]$Config,
    [string]$Program,
    [string[]]$Breakpoint,
    [string[]]$Watch,
    [switch]$LoadProgram,
    [switch]$RestartTarget,
    [switch]$AllowHardware,
    [switch]$AllowProgramLoad,
    [switch]$AllowRun,
    [switch]$NoPanel
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $projectRoot
if ([string]::IsNullOrWhiteSpace($CcsRoot)) { $CcsRoot = [string]$settings.CcsRoot }
$debugRoot = [string]$settings.RuntimeDirectory
$currentSessionPath = Join-Path $debugRoot 'current-session.json'
$dssPath = Join-Path $CcsRoot 'ccs_base\scripting\bin\dss.bat'
$scriptPath = Join-Path $PSScriptRoot 'AutoDebugHold.js'
$runnerPath = Join-Path $PSScriptRoot 'RunSharedDebug.ps1'
$panelPath = Join-Path $PSScriptRoot 'SharedDebugPanel.ps1'
$stylesheetPath = Join-Path $CcsRoot 'ccs_base\scripting\examples\DebugServerExamples\DefaultStylesheet.xsl'

if (-not $AllowHardware) {
    throw 'Starting a shared debug session connects to XDS2xx. Re-run with -AllowHardware.'
}
if ($LoadProgram -and -not $AllowProgramLoad) {
    throw 'Loading a program writes target memory. Re-run with -AllowProgramLoad.'
}
if ($RestartTarget -and -not $AllowRun) {
    throw 'RestartTarget runs the CPU. Re-run with -AllowRun.'
}

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = [string]$settings.TargetConfig
}
if ([string]::IsNullOrWhiteSpace($Program)) {
    $Program = [string]$settings.Program
}
if ($null -eq $Breakpoint -or $Breakpoint.Count -eq 0) {
    $Breakpoint = @()
}
if ($null -eq $Watch -or $Watch.Count -eq 0) {
    $Watch = @($settings.DefaultWatch)
}

foreach ($requiredFile in @($dssPath, $scriptPath, $runnerPath, $stylesheetPath, $Config, $Program)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file does not exist: $requiredFile"
    }
}

$sourceRoot = [string]$settings.SourceRoot
$newestSource = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse |
    Where-Object { $_.Extension -in @('.c', '.C', '.h') } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$programInfo = Get-Item -LiteralPath $Program
if ($null -ne $newestSource -and $newestSource.LastWriteTime -gt $programInfo.LastWriteTime) {
    Write-Warning "Program symbols may be stale. Newest source: $($newestSource.FullName); program: $Program"
}

if (Get-Process -Name 'ccstudio' -ErrorAction SilentlyContinue) {
    Write-Host 'CCS editor is running. This is allowed; only its active Debug session must be disconnected.'
}

if (Test-Path -LiteralPath $currentSessionPath -PathType Leaf) {
    try {
        $current = Get-Content -Raw -LiteralPath $currentSessionPath | ConvertFrom-Json
        if ($current.ProcessId -and (Get-Process -Id ([int]$current.ProcessId) -ErrorAction SilentlyContinue)) {
            throw "A shared debug session is already running (PID $($current.ProcessId))."
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
    }
}

New-Item -ItemType Directory -Force -Path $debugRoot | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$sessionDirectory = Join-Path $debugRoot "Shared-$timestamp"
$commandDirectory = Join-Path $sessionDirectory 'commands'
New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null

$statusPath = Join-Path $sessionDirectory 'status.txt'
$eventsPath = Join-Path $sessionDirectory 'events.log'
$logPath = Join-Path $sessionDirectory 'dss.xml'
$stdoutPath = Join-Path $sessionDirectory 'dss.stdout.log'
$stderrPath = Join-Path $sessionDirectory 'dss.stderr.log'
$sessionPath = Join-Path $sessionDirectory 'session.json'

$dssArguments = @(
    $scriptPath,
    "--config=$((Resolve-Path -LiteralPath $Config).Path)",
    "--program=$((Resolve-Path -LiteralPath $Program).Path)",
    "--breakpoints=$($Breakpoint -join ';')",
    "--watch=$($Watch -join ';')",
    "--status=$statusPath",
    "--commanddir=$commandDirectory",
    "--events=$eventsPath",
    "--log=$logPath",
    "--stylesheet=$((Resolve-Path -LiteralPath $stylesheetPath).Path)",
    "--loadprogram=$($LoadProgram.IsPresent.ToString().ToLowerInvariant())",
    "--restart=$($RestartTarget.IsPresent.ToString().ToLowerInvariant())"
)

$session = [ordered]@{
    Version = 1
    ProcessId = $null
    Started = (Get-Date).ToString('o')
    ProjectRoot = $projectRoot
    SessionDirectory = $sessionDirectory
    CommandDirectory = $commandDirectory
    StatusPath = $statusPath
    EventsPath = $eventsPath
    LogPath = $logPath
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    Config = (Resolve-Path -LiteralPath $Config).Path
    Program = (Resolve-Path -LiteralPath $Program).Path
    Breakpoints = $Breakpoint
    Watch = $Watch
    LoadProgram = $LoadProgram.IsPresent
    RestartTarget = $RestartTarget.IsPresent
    DssPath = $dssPath
    DssArguments = $dssArguments
}
$session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sessionPath -Encoding UTF8
$process = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, '-SessionPath', $sessionPath) `
    -WorkingDirectory $projectRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru
$session.ProcessId = $process.Id
$session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sessionPath -Encoding UTF8
$session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentSessionPath -Encoding UTF8

$deadline = (Get-Date).AddSeconds(8)
while (-not (Test-Path -LiteralPath $statusPath -PathType Leaf) -and -not $process.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
}
if ($process.HasExited -and -not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    $stderr = if (Test-Path -LiteralPath $stderrPath) { ([string](Get-Content -Raw -LiteralPath $stderrPath)).Trim() } else { '' }
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { ([string](Get-Content -Raw -LiteralPath $stdoutPath)).Trim() } else { '' }
    $detail = @($stderr, $stdout) | Where-Object { $_ } | Select-Object -First 1
    if (-not $detail) { $detail = "DSS exited with code $($process.ExitCode) before creating a status file." }
    [IO.File]::WriteAllText($statusPath, "ERROR;message=$($detail -replace '[\r\n;]+', ' ')", [Text.Encoding]::UTF8)
    throw $detail
}

if (-not $NoPanel) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $panelPath) | Out-Null
}

Write-Host "Shared debug session started. PID: $($process.Id)"
Write-Host "Session: $sessionPath"
Write-Host "Status:  $statusPath"
