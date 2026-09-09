[CmdletBinding()]
param(
    [ValidateSet('Status', 'Read', 'Snapshot', 'AddBreakpoint', 'Pause', 'Resume', 'ReadLog')]
    [string]$Action = 'Status',
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$IarProcessId,
    [string[]]$Expression = @(),
    [string]$SourceFile,
    [int]$Line,
    [string]$LogFile,
    [int]$Tail = 40,
    [ValidateRange(1, 60)][int]$TimeoutSeconds = 8
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('IarSessionNativeV1' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class IarSessionNativeV1 {
 [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr window);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int pos);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int pos);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint pos, StringBuilder text, int max, uint flags);
 [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint pos, uint flags);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint msg, IntPtr wp, IntPtr lp);
 [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", SetLastError=true)] public static extern IntPtr SendRaw(IntPtr window, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr result);
 [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr SendText(IntPtr window, uint msg, IntPtr wp, string lp, uint flags, uint timeout, out IntPtr result);
}
'@
}

# Select the IDE that was opened with a workspace/project under the requested root.
# Do not fall back to an unrelated IDE with the same project name.
$candidates = @(Get-CimInstance Win32_Process -Filter "Name='IarIdePm.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($ProjectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($IarProcessId) { $candidates = @($candidates | Where-Object ProcessId -eq $IarProcessId) }
if ($candidates.Count -ne 1) {
    throw "Expected one IAR process opened with a project under '$ProjectRoot'; found $($candidates.Count). Open the .eww explicitly, or select -IarProcessId when multiple instances match."
}
$iarProcess = $candidates[0]
$processCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$iarProcess.ProcessId)
$windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $processCondition)
$mainWindows = @($windows | Where-Object { $_.Current.Name -match ' - IAR Embedded Workbench IDE' })
if ($mainWindows.Count -ne 1) { throw 'IAR main window is missing or ambiguous.' }
$requestMutex = [Threading.Mutex]::new($false, "Local\IarCoop-$($iarProcess.ProcessId)")
$lockAcquired = $false
try {
try { $lockAcquired = $requestMutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
if (-not $lockAcquired) { throw 'Another command is already using this IAR session.' }
$window = $mainWindows[0]
$windowHandle = [IntPtr]$window.Current.NativeWindowHandle
$windowTitle = $window.Current.Name
$menuHandle = [IarSessionNativeV1]::GetMenu($windowHandle)
if ($menuHandle -eq [IntPtr]::Zero -or -not $window.Current.IsEnabled) { throw 'IAR menu unavailable or a modal dialog is blocking the IDE.' }

function Send-IarRaw([IntPtr]$Handle, [uint32]$Message, [IntPtr]$WParam, [IntPtr]$LParam) {
    $result = [IntPtr]::Zero
    if ([IarSessionNativeV1]::SendRaw($Handle, $Message, $WParam, $LParam, 2, 2000, [ref]$result) -eq [IntPtr]::Zero) {
        throw "IAR window request timed out or failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
}
function Get-IarMenus([IntPtr]$Menu, [string]$Prefix = '') {
    for ($i = 0; $i -lt [IarSessionNativeV1]::GetMenuItemCount($Menu); $i++) {
        $buffer = [Text.StringBuilder]::new(512)
        [void][IarSessionNativeV1]::GetMenuString($Menu, $i, $buffer, 512, 1024)
        $name = (($buffer.ToString() -split "`t")[0] -replace '&', '')
        if (-not $name) { continue }
        $path = "$Prefix/$name"
        $sub = [IarSessionNativeV1]::GetSubMenu($Menu, $i)
        if ($sub -ne [IntPtr]::Zero) { Get-IarMenus $sub $path }
        else { [pscustomobject]@{ Path = $path; Id = [IarSessionNativeV1]::GetMenuItemID($Menu, $i); Enabled = (([IarSessionNativeV1]::GetMenuState($Menu, $i, 1024) -band 3) -eq 0) } }
    }
}
function Get-IarState {
    # MFC caches menu enablement; ask it to update the Debug menu before reading it.
    for ($i = 0; $i -lt [IarSessionNativeV1]::GetMenuItemCount($menuHandle); $i++) {
        $buffer = [Text.StringBuilder]::new(128)
        [void][IarSessionNativeV1]::GetMenuString($menuHandle, $i, $buffer, 128, 1024)
        if (($buffer.ToString() -replace '&', '') -eq 'Debug') {
            Send-IarRaw $windowHandle 279 ([IarSessionNativeV1]::GetSubMenu($menuHandle, $i)) ([IntPtr]$i)
        }
    }
    $menus = @(Get-IarMenus $menuHandle)
    $go = @($menus | Where-Object Path -eq '/Debug/Go')
    $stop = @($menus | Where-Object Path -eq '/Debug/Break')
    $state = 'Unknown'
    if ($go.Count -eq 1 -and $stop.Count -eq 1) {
        if ($go[0].Enabled -and -not $stop[0].Enabled) { $state = 'Stopped' }
        elseif ($stop[0].Enabled -and -not $go[0].Enabled) { $state = 'Running' }
    }
    [pscustomobject]@{ ProcessId = [int]$iarProcess.ProcessId; Title = $windowTitle; State = $state; ObservedAt = (Get-Date).ToString('o') }
}
function Invoke-IarMenu([string]$Path) {
    $matches = @(Get-IarMenus $menuHandle | Where-Object Path -eq $Path)
    if ($matches.Count -ne 1 -or -not $matches[0].Enabled) { throw "IAR command unavailable: $Path" }
    if (-not [IarSessionNativeV1]::PostMessage($windowHandle, 273, [IntPtr]$matches[0].Id, [IntPtr]::Zero)) { throw "Failed to post IAR command: $Path" }
}
function Get-QuickWatchControls {
    $quickCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Quick Watch')
    $quick = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $quickCondition)
    if ($null -eq $quick) { return }
    $children = @($quick.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
    $edits = @($children | Where-Object { $_.Current.ClassName -eq 'Edit' })
    $buttons = @($children | Where-Object { $_.Current.ClassName -eq 'Button' -and $_.Current.Name -match '^Recalculate' })
    if ($edits.Count -eq 1 -and $buttons.Count -eq 1 -and $buttons[0].Current.IsEnabled) {
        [pscustomobject]@{ Edit = $edits[0]; Button = $buttons[0] }
    }
}
function Invoke-QuickExpression([string]$Text) {
    if (-not $window.Current.IsEnabled) { throw 'An IAR modal dialog blocks evaluation.' }
    if ((Get-IarState).State -ne 'Stopped') { throw 'Expression rejected: CPU must already be stopped. Use -Action Pause explicitly.' }
    $controls = Get-QuickWatchControls
    if ($null -eq $controls) { throw 'Quick Watch controls unavailable; no input sent.' }
    $result = [IntPtr]::Zero
    if ([IarSessionNativeV1]::SendText([IntPtr]$controls.Edit.Current.NativeWindowHandle, 12, [IntPtr]::Zero, $Text, 2, 2000, [ref]$result) -eq [IntPtr]::Zero) { throw 'Unable to set Quick Watch expression.' }
    if ($controls.Edit.Current.Name -ne $Text) { throw 'Quick Watch expression verification failed; evaluation cancelled.' }
    if (-not [IarSessionNativeV1]::PostMessage([IntPtr]$controls.Button.Current.NativeWindowHandle, 245, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Unable to request expression evaluation.' }
}
function Quote-IarString([string]$Text) { '"' + $Text.Replace('\', '\\').Replace('"', '\"') + '"' }
function Read-IarExpression([string]$Text) {
    $resultFile = Join-Path $runtime ([guid]::NewGuid().ToString('N') + '.txt')
    Invoke-QuickExpression ($macroFunction + '(' + (Quote-IarString $Text) + ', ' + (Quote-IarString $resultFile) + ')')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $resultFile) {
            try { $raw = [IO.File]::ReadAllText($resultFile, [Text.Encoding]::Default) }
            catch [IO.IOException] { Start-Sleep -Milliseconds 100; continue }
            if ($raw -match '(?m)^complete=1\r?$') {
                $errorMatch = [regex]::Match($raw, '(?m)^error=(\d+)\r?$')
                if (-not $errorMatch.Success -or $errorMatch.Groups[1].Value -ne '0') { throw "C-SPY evaluation failed for '$Text'. Result: $resultFile" }
                $valueMatch = [regex]::Match($raw, '(?ms)^value=(.*?)\r?\ncomplete=1')
                return [pscustomobject]@{ Expression = $Text; Value = $valueMatch.Groups[1].Value; ResultFile = $resultFile; ObservedAt = (Get-Date).ToString('o') }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw "No completed C-SPY response for '$Text'. Do not assume the command failed or retry mutations blindly. Inspect IAR Quick Watch and Debug Log. Expected result: $resultFile"
}

$before = Get-IarState
if ($Action -eq 'Status') { $before; return }
if ($Action -eq 'ReadLog') {
    if (-not $LogFile) { throw 'Provide the actual IAR Debug Log path with -LogFile; no filename is assumed.' }
    $log = Get-Item -LiteralPath $LogFile
    [pscustomobject]@{ Path = $log.FullName; LastWriteTime = $log.LastWriteTime; Length = $log.Length; Content = (Get-Content -LiteralPath $log.FullName -Tail $Tail) -join "`n" }
    return
}
if ($Action -eq 'Resume') {
    if ($before.State -eq 'Running') { $before; return }
    if ($before.State -ne 'Stopped') { throw 'Cannot resume an unknown or inactive debug session.' }
    Invoke-IarMenu '/Debug/Go'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $after = Get-IarState
        if ($after.State -eq 'Running') { $after; return }
        if ($after.State -ne 'Stopped') { break }
    } while ((Get-Date) -lt $deadline)
    throw 'Go was sent once but Running was not observed; the target may have stopped again. Inspect Status and Debug Log; do not retry automatically.'
}
if ($Action -eq 'Pause') {
    if ($before.State -eq 'Running') {
        Invoke-IarMenu '/Debug/Break'
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do { Start-Sleep -Milliseconds 100; $after = Get-IarState } while ($after.State -eq 'Running' -and (Get-Date) -lt $deadline)
        if ($after.State -ne 'Stopped') { throw 'Pause was requested but stopped state was not confirmed.' }
        $after
    } elseif ($before.State -eq 'Stopped') { $before }
    else { throw 'Cannot pause an unknown or inactive debug session.' }
    return
}
if ($before.State -ne 'Stopped') { throw 'CPU is not stopped. Read/Snapshot/AddBreakpoint never pause it implicitly.' }
if ($Action -eq 'Read' -and $Expression.Count -eq 0) { throw 'Read requires -Expression.' }
foreach ($item in $Expression) {
    # Read accepts scalar symbol/member/constant-index paths and CPU registers only.
    if ($item -notmatch '^(#[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[[0-9]+\]))*)$') { throw "Not a read-only symbol path: $item" }
}
if ($Action -eq 'AddBreakpoint') {
    if (-not $SourceFile -or $Line -lt 1) { throw 'AddBreakpoint requires -SourceFile and a positive -Line.' }
    $source = (Resolve-Path -LiteralPath $SourceFile).Path
    if (-not $source.StartsWith($ProjectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Breakpoint source must be inside the selected project root.' }
    if ($Line -gt [IO.File]::ReadAllLines($source).Count) { throw 'Breakpoint line exceeds file length.' }
}

$runtime = Join-Path $ProjectRoot 'Debug\IarSession'
[void][IO.Directory]::CreateDirectory($runtime)
$template = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'IarSession.mac')).Path
$macroHash = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.Substring(0, 16)
$macroFunction = 'IarCoopEvaluate_' + $macroHash
$macro = Join-Path $runtime ("bridge-$macroHash.mac")
if (-not (Test-Path -LiteralPath $macro)) {
    [IO.File]::WriteAllText($macro, [IO.File]::ReadAllText($template).Replace('@REV@', $macroHash), [Text.UTF8Encoding]::new($false))
}
$registrationFile = Join-Path $runtime ("registration-$($iarProcess.ProcessId)-$macroHash.json")
$registered = $false
if (Test-Path -LiteralPath $registrationFile) {
    $registration = Get-Content -LiteralPath $registrationFile -Raw | ConvertFrom-Json
    $registered = ($registration.ProcessCreated -eq $iarProcess.CreationDate.ToString('o'))
}
if (-not (Get-QuickWatchControls)) { Invoke-IarMenu '/View/Quick Watch' }
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do { $controls = Get-QuickWatchControls; if ($controls) { break }; Start-Sleep -Milliseconds 100 } while ((Get-Date) -lt $deadline)
if (-not $controls) { throw 'Quick Watch did not become available.' }
if (-not $registered) {
    Invoke-QuickExpression ('__registerMacroFile(' + (Quote-IarString $macro) + ')')
    Start-Sleep -Milliseconds 250
}
# A debugger restart can discard macros without restarting the IDE process.
# Only the harmless handshake is retried; breakpoint mutations are never retried.
try { $handshake = Read-IarExpression '__isBatchMode()' }
catch {
    if (-not $registered) { throw }
    Invoke-QuickExpression ('__registerMacroFile(' + (Quote-IarString $macro) + ')')
    Start-Sleep -Milliseconds 250
    $handshake = Read-IarExpression '__isBatchMode()'
}
if ($handshake.Value -ne '0') { throw 'Unexpected C-SPY mode; GUI session handshake failed.' }
[IO.File]::WriteAllText($registrationFile, (@{ ProcessCreated = $iarProcess.CreationDate.ToString('o'); MacroHash = $macroHash } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

switch ($Action) {
    'Read' { foreach ($item in $Expression) { Read-IarExpression $item } }
    'Snapshot' {
        Read-IarExpression '#PC'
        Read-IarExpression '__iar_source_position__'
        foreach ($item in $Expression) { Read-IarExpression $item }
    }
    'AddBreakpoint' {
        $location = '{' + $source + '}.' + $Line + '.1'
        $command = '__setCodeBreak(' + (Quote-IarString $location) + ', 0, "1", "TRUE", "")'
        $response = Read-IarExpression $command
        if ($response.Value -notmatch '^\d+$' -or [uint64]$response.Value -eq 0) { throw "C-SPY did not return a valid breakpoint ID: $($response.Value)" }
        [pscustomobject]@{ ProcessId = [int]$iarProcess.ProcessId; SourceFile = $source; RequestedLine = $Line; BreakpointId = $response.Value; State = (Get-IarState).State; ResultFile = $response.ResultFile; Note = 'C-SPY accepted the breakpoint. Verify the resolved instruction location in IAR; optimized code may map to a nearby line.' }
    }
}

} finally {
    if ($lockAcquired) { $requestMutex.ReleaseMutex() }
    $requestMutex.Dispose()
}
