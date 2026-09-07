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
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if ([string]::IsNullOrWhiteSpace($Command)) { throw 'A shared debug command cannot be empty.' }
if ($Command -match '[\r\n\x00]') { throw 'A shared debug command must be a single line.' }
if ($Command.Length -gt 4096) { throw 'A shared debug command is limited to 4096 characters.' }

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot
$currentSessionPath = Join-Path ([string]$settings.RuntimeDirectory) 'current-session.json'
if (-not (Test-Path -LiteralPath $currentSessionPath -PathType Leaf)) {
    throw 'No shared debug session exists. Start Tools\StartSharedDebug.ps1 first.'
}

$session = Get-Content -Raw -LiteralPath $currentSessionPath -Encoding UTF8 | ConvertFrom-Json
if (-not $session.CommandDirectory -or -not $session.StatusPath -or -not $session.EventsPath) {
    throw 'The active session is incomplete and does not expose the shared queue and logs.'
}
if ($session.ProcessId) {
    $process = Get-Process -Id ([int]$session.ProcessId) -ErrorAction SilentlyContinue
    if (-not $process) {
        throw 'The shared debug backend is no longer running. Inspect the session status and event log before starting a new session.'
    }
}

$status = if (Test-Path -LiteralPath $session.StatusPath -PathType Leaf) {
    (Get-Content -Raw -LiteralPath $session.StatusPath -Encoding UTF8).Trim()
}
else { '' }
if ($status.StartsWith('STOPPED') -or $status.StartsWith('ERROR')) {
    throw "The shared debug session is not active: $status"
}

$commandDirectory = [string]$session.CommandDirectory
New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null
$id = '{0:yyyyMMddHHmmssfffffff}-{1}-{2}' -f (Get-Date), $PID, ([Guid]::NewGuid().ToString('N'))
$temporaryPath = Join-Path $commandDirectory "$id.tmp"
$commandPath = Join-Path $commandDirectory "$id.cmd"
[IO.File]::WriteAllText($temporaryPath, $Command.Trim(), [Text.Encoding]::ASCII)
Move-Item -LiteralPath $temporaryPath -Destination $commandPath

if ($WaitMs -gt 0) { Start-Sleep -Milliseconds $WaitMs }

if (Test-Path -LiteralPath $session.StatusPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $session.StatusPath -Encoding UTF8
}
if (Test-Path -LiteralPath $session.EventsPath -PathType Leaf) {
    Get-Content -LiteralPath $session.EventsPath -Encoding UTF8 -Tail 8
}
