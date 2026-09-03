[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath
)

$ErrorActionPreference = 'Stop'
$session = Get-Content -Raw -LiteralPath $SessionPath | ConvertFrom-Json
$dssPath = [string]$session.DssPath
$dssArguments = @($session.DssArguments | ForEach-Object { [string]$_ })

if (-not (Test-Path -LiteralPath $dssPath -PathType Leaf)) {
    throw "DSS launcher does not exist: $dssPath"
}
if ($dssArguments.Count -eq 0) {
    throw 'The shared debug session does not contain DSS arguments.'
}

& $dssPath @dssArguments
exit $LASTEXITCODE

