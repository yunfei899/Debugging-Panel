[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$Configuration
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot
if ([string]::IsNullOrWhiteSpace($Configuration)) { $Configuration = [string]$settings.IarConfiguration }

$iarBuildPath = [string]$settings.IarBuild
$projectFile = [string]$settings.IarProject
$customArgVarsFile = [string]$settings.IarCustomArgVars
$runtimeDirectory = [string]$settings.RuntimeDirectory
$statusPath = Join-Path $runtimeDirectory 'build-status.txt'
$logPath = Join-Path $runtimeDirectory 'build.log'
$stdoutPath = Join-Path $runtimeDirectory 'build.stdout.tmp'
$stderrPath = Join-Path $runtimeDirectory 'build.stderr.tmp'

New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null

function Write-BuildStatus([string]$Value) {
    [IO.File]::WriteAllText($statusPath, $Value, $utf8NoBom)
}

try {
    foreach ($requiredFile in @($iarBuildPath, $projectFile, $customArgVarsFile)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required IAR build file does not exist: $requiredFile"
        }
    }

    Write-BuildStatus "BUILDING;configuration=$Configuration;started=$([DateTime]::Now.ToString('s'))"
    $arguments = @($projectFile, '-build', $Configuration, '-log', 'all', '-varfile', $customArgVarsFile)
    $buildProcess = Start-Process -FilePath $iarBuildPath `
        -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $projectFile) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -Wait -PassThru

    $output = @()
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stderrPath) }
    [IO.File]::WriteAllLines($logPath, [string[]]$output, $utf8NoBom)
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    if ($buildProcess.ExitCode -ne 0) {
        Write-BuildStatus "FAILED;configuration=$Configuration;exitCode=$($buildProcess.ExitCode);finished=$([DateTime]::Now.ToString('s'));log=$logPath"
        exit $buildProcess.ExitCode
    }

    if (-not (Test-Path -LiteralPath ([string]$settings.Program) -PathType Leaf)) {
        throw "IAR build reported success, but the debug program was not found: $([string]$settings.Program)"
    }
    Write-BuildStatus "SUCCESS;configuration=$Configuration;exitCode=0;finished=$([DateTime]::Now.ToString('s'));program=$([string]$settings.Program);log=$logPath"
}
catch {
    $message = $_.Exception.Message -replace '[\r\n;]+', ' '
    [IO.File]::WriteAllText($logPath, $message, $utf8NoBom)
    Write-BuildStatus "FAILED;message=$message;finished=$([DateTime]::Now.ToString('s'));log=$logPath"
    exit 1
}
