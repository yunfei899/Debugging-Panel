[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$buildDirectoryRelative = 'projects\Windows\Debug'
$targetConfigRelative = 'projects\Windows\targetConfigs\TMS320F28335.ccxml'
$programRelative = 'projects\Windows\Debug\Easy6_STD.out'
$sourceRootRelative = 'Easy6\Source'

$requiredSettings = [ordered]@{
    buildDirectoryRelative = $buildDirectoryRelative
    targetConfigRelative = $targetConfigRelative
    programRelative = $programRelative
    sourceRootRelative = $sourceRootRelative
}
$missingSettings = @($requiredSettings.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object { $_.Key })
if ($missingSettings.Count -gt 0) {
    throw "Shared debug template is not configured. Edit Tools\SharedDebugConfig.ps1: $($missingSettings -join ', ')"
}

[ordered]@{
    CcsRoot = 'C:\software\CCS\ccs'
    RuntimeDirectory = Join-Path $ProjectRoot 'Debug\AutoDebug'
    BuildDirectory = Join-Path $ProjectRoot $buildDirectoryRelative
    TargetConfig = Join-Path $ProjectRoot $targetConfigRelative
    Program = Join-Path $ProjectRoot $programRelative
    SourceRoot = Join-Path $ProjectRoot $sourceRootRelative
    DefaultWatch = @('errPLC', 'ipstep')
}
