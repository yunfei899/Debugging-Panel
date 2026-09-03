[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$CcsRoot
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
if ([string]::IsNullOrWhiteSpace($CcsRoot)) { $CcsRoot = [string]$settings.CcsRoot }

$buildDirectory = [string]$settings.BuildDirectory
$makefilePath = Join-Path $buildDirectory 'makefile'
$gmakePath = Join-Path $CcsRoot 'utils\bin\gmake.exe'
$outputDirectory = [string]$settings.RuntimeDirectory
$statusPath = Join-Path $outputDirectory 'build-status.txt'
$logPath = Join-Path $outputDirectory 'build.log'
$stdoutPath = Join-Path $outputDirectory 'build.stdout.tmp'
$stderrPath = Join-Path $outputDirectory 'build.stderr.tmp'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
[IO.File]::WriteAllText($statusPath, "BUILDING;started=$([DateTime]::Now.ToString('s'))", $utf8NoBom)

try {
    if (-not (Test-Path -LiteralPath $makefilePath -PathType Leaf)) {
        throw "Build makefile was not found: $makefilePath"
    }
    if (-not (Test-Path -LiteralPath $gmakePath -PathType Leaf)) {
        throw "CCS gmake was not found: $gmakePath"
    }

    $buildProcess = Start-Process -FilePath $gmakePath `
        -ArgumentList @('--no-print-directory', 'all') `
        -WorkingDirectory $buildDirectory `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $exitCode = $buildProcess.ExitCode
    $output = @()
    if (Test-Path -LiteralPath $stdoutPath) { $output += @(Get-Content -LiteralPath $stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath) { $output += @(Get-Content -LiteralPath $stderrPath) }
    [IO.File]::WriteAllLines($logPath, [string[]]$output, $utf8NoBom)
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) {
        [IO.File]::WriteAllText($statusPath, "FAILED;exitCode=$exitCode;finished=$([DateTime]::Now.ToString('s'));log=$logPath", $utf8NoBom)
        exit $exitCode
    }

    [IO.File]::WriteAllText($statusPath, "SUCCESS;exitCode=0;finished=$([DateTime]::Now.ToString('s'));log=$logPath", $utf8NoBom)
}
catch {
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    [IO.File]::WriteAllText($logPath, $message, $utf8NoBom)
    [IO.File]::WriteAllText($statusPath, "FAILED;message=$message;finished=$([DateTime]::Now.ToString('s'));log=$logPath", $utf8NoBom)
    exit 1
}
