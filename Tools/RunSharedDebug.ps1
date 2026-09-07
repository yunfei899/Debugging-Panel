[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath
)

$ErrorActionPreference = 'Stop'
$session = Get-Content -Raw -LiteralPath $SessionPath | ConvertFrom-Json
$backendPath = Join-Path $PSScriptRoot 'IarGdbSession.ps1'
if ($session.BackendPath) { $backendPath = [string]$session.BackendPath }

if (-not (Test-Path -LiteralPath $backendPath -PathType Leaf)) {
    throw "Shared debug backend does not exist: $backendPath"
}

& $backendPath -SessionPath $SessionPath
exit $LASTEXITCODE
