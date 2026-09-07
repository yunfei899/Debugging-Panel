[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$Program,
    [string]$EventsPath,
    [string]$StatusPath,
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
    throw 'IAR C-SPY download connects to the J-Link target. Re-run with -AllowHardware.'
}
if (-not $AllowProgramLoad) {
    throw 'IAR C-SPY download writes target memory. Re-run with -AllowProgramLoad.'
}

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot
if ([string]::IsNullOrWhiteSpace($Program)) { $Program = [string]$settings.Program }
if (-not [IO.Path]::IsPathRooted($Program)) { $Program = Join-Path $ProjectRoot $Program }
$Program = [IO.Path]::GetFullPath($Program)

$requiredFiles = @(
    [string]$settings.CspyBat,
    [string]$settings.CspyGeneralSettings,
    [string]$settings.CspyDriverSettings,
    $Program
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required IAR download file does not exist: $requiredFile"
    }
}

if ([string]::IsNullOrWhiteSpace($EventsPath)) {
    $EventsPath = Join-Path ([string]$settings.RuntimeDirectory) 'cspy-download.events.log'
}
if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    $StatusPath = Join-Path ([string]$settings.RuntimeDirectory) 'cspy-download.status.txt'
}
$eventsDirectory = Split-Path -Parent $EventsPath
$statusDirectory = Split-Path -Parent $StatusPath
New-Item -ItemType Directory -Force -Path $eventsDirectory, $statusDirectory | Out-Null

function Write-DownloadStatus([string]$Value) {
    [IO.File]::WriteAllText($StatusPath, $Value, $utf8NoBom)
}

function Write-DownloadEvent([string]$Value) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')`t$($Value -replace '[\r\n]+', ' ')" + [Environment]::NewLine
    [IO.File]::AppendAllText($EventsPath, $line, $utf8NoBom)
}

$sessionDirectory = Split-Path -Parent $EventsPath
$stdoutPath = Join-Path $sessionDirectory 'cspy-download.stdout.log'
$stderrPath = Join-Path $sessionDirectory 'cspy-download.stderr.log'
$workingDirectory = Split-Path -Parent ([string]$settings.IarProject)
$arguments = @(
    '-f', [string]$settings.CspyGeneralSettings,
    "--debug_file=$((Resolve-Path -LiteralPath $Program).Path)",
    '--download_only'
)
if ([bool]$settings.IarBreakResetGo) {
    $arguments += '--leave_target_running'
}
$arguments += @(
    '--backend',
    '-f', [string]$settings.CspyDriverSettings
)

try {
    Write-DownloadStatus "DOWNLOADING;started=$([DateTime]::Now.ToString('s'))"
    Write-DownloadEvent "CSPY_DOWNLOAD_START program=$Program"
    if ([bool]$settings.IarBreakResetGo) {
        Write-DownloadEvent 'CSPY_BREAK_RESET_GO START'
    }
    $process = Start-Process -FilePath ([string]$settings.CspyBat) `
        -ArgumentList $arguments `
        -WorkingDirectory $workingDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -Wait -PassThru

    $output = @()
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stderrPath) }
    if ($output.Count -gt 0) {
        Write-DownloadEvent ("CSPY_OUTPUT " + (($output -join ' ') -replace '[\r\n]+', ' '))
    }

    if ($process.ExitCode -ne 0) {
        $detail = (($output -join ' ') -replace '[\r\n]+', ' ').Trim()
        if (-not $detail) { $detail = "cspybat exited with code $($process.ExitCode)." }
        Write-DownloadStatus "FAILED;exitCode=$($process.ExitCode);message=$detail"
        Write-DownloadEvent "CSPY_DOWNLOAD_ERROR $detail"
        throw $detail
    }

    Write-DownloadStatus "SUCCESS;finished=$([DateTime]::Now.ToString('s'));program=$Program"
    Write-DownloadEvent "CSPY_DOWNLOAD_OK program=$Program"
    if ([bool]$settings.IarBreakResetGo) {
        Write-DownloadEvent 'CSPY_BREAK_RESET_GO OK target=running'
    }
}
catch {
    $message = $_.Exception.Message -replace '[\r\n;]+', ' '
    Write-DownloadStatus "FAILED;message=$message"
    Write-DownloadEvent "CSPY_DOWNLOAD_ERROR $message"
    throw $message
}
