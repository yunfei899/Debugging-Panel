[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command,
    [string]$ProjectRoot,
    [ValidateRange(0, 30000)]
    [int]$WaitMs = 500
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
$currentSessionPath = Join-Path ([string]$settings.RuntimeDirectory) 'current-session.json'
if (-not (Test-Path -LiteralPath $currentSessionPath -PathType Leaf)) {
    throw 'No shared debug session exists. Start Tools\StartSharedDebug.ps1 first.'
}

$session = Get-Content -Raw -LiteralPath $currentSessionPath | ConvertFrom-Json
if (-not $session.CommandDirectory) {
    throw 'The active session does not expose a command queue.'
}

$commandDirectory = [string]$session.CommandDirectory
New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null
$id = '{0:yyyyMMddHHmmssfffffff}-{1}-{2}' -f (Get-Date), $PID, ([Guid]::NewGuid().ToString('N'))
$temporaryPath = Join-Path $commandDirectory "$id.tmp"
$commandPath = Join-Path $commandDirectory "$id.cmd"
[IO.File]::WriteAllText($temporaryPath, $Command, [Text.Encoding]::ASCII)
Move-Item -LiteralPath $temporaryPath -Destination $commandPath

if ($WaitMs -gt 0) {
    Start-Sleep -Milliseconds $WaitMs
}

if (Test-Path -LiteralPath $session.StatusPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $session.StatusPath
}
if (Test-Path -LiteralPath $session.EventsPath -PathType Leaf) {
    Get-Content -LiteralPath $session.EventsPath -Tail 5
}
