[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SessionPath
)

$ErrorActionPreference = 'Stop'

$session = Get-Content -Raw -LiteralPath $SessionPath | ConvertFrom-Json
$statusPath = [string]$session.StatusPath
$eventsPath = [string]$session.EventsPath
$commandDirectory = [string]$session.CommandDirectory
$gdbPath = [string]$session.GdbPath
$jlinkPath = [string]$session.JLinkGdbServerPath
$programPath = [string]$session.Program
$gdbHost = [string]$session.GdbServerHost
$gdbPort = [int]$session.GdbServerPort
$utf8NoBom = New-Object Text.UTF8Encoding($false)

$script:gdbProcess = $null
$script:jlinkProcess = $null
$script:jlinkProcessId = $null
$script:gdbOutputReader = $null
$script:gdbErrorReader = $null
$script:gdbOutputReadTask = $null
$script:gdbErrorReadTask = $null
$script:gdbOutputQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:gdbErrorQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:miToken = 0
$script:targetState = 'STARTING'
$script:previousState = ''
$script:manualStopPending = $false
$script:keepRunning = $true
$script:fatalError = $false
$script:watchExpressions = @($session.Watch | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$script:breakpoints = [ordered]@{}

function Get-CleanText([string]$Value) {
    if ($null -eq $Value) { return '' }
    return ($Value -replace '[\r\n]+', ' ' -replace '\s{2,}', ' ').Trim()
}

function Write-Status([string]$Value) {
    $directory = Split-Path -Parent $statusPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$statusPath.$PID.tmp"
    $maximumAttempts = 20

    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            [IO.File]::WriteAllText($temporaryPath, $Value, $utf8NoBom)
            if ([IO.File]::Exists($statusPath)) {
                [IO.File]::Replace($temporaryPath, $statusPath, [NullString]::Value)
            }
            else {
                [IO.File]::Move($temporaryPath, $statusPath)
            }
            return
        }
        catch [IO.IOException] {
            if ($attempt -eq $maximumAttempts) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Write-Event([string]$Value) {
    $directory = Split-Path -Parent $eventsPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')`t$(Get-CleanText $Value)" + [Environment]::NewLine
    [IO.File]::AppendAllText($eventsPath, $line, $utf8NoBom)
}

function Publish-Status {
    $parts = @($script:targetState)
    if ($script:gdbProcess) { $parts += "gdbPid=$($script:gdbProcess.Id)" }
    if ($script:jlinkProcess) { $parts += "jlinkPid=$($script:jlinkProcess.Id)" }
    elseif ($null -ne $script:jlinkProcessId) { $parts += "jlinkPid=$($script:jlinkProcessId)" }
    Write-Status ($parts -join ';')
}

function ConvertTo-MiString([string]$Value) {
    if ($null -eq $Value) { return '' }
    $result = $Value.Replace('\', '\\')
    $result = $result.Replace('"', '\"')
    $result = $result.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return $result
}

function ConvertFrom-MiString([string]$Value) {
    if ($null -eq $Value) { return '' }
    $result = $Value.Replace('\n', "`n").Replace('\r', "`r").Replace('\t', "`t")
    $result = $result.Replace('\"', '"').Replace('\\', '\')
    return $result
}

function ConvertTo-ProcessArgumentString([string[]]$Arguments) {
    $quoted = foreach ($argument in @($Arguments)) {
        $text = [string]$argument
        if ($text -notmatch '[\s"]') {
            $text
        }
        else {
            '"' + $text.Replace('"', '\"') + '"'
        }
    }
    return $quoted -join ' '
}

function Read-ChildLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return ((Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue) -join '').Trim()
}

function Get-TcpPortOwner {
    try {
        $connection = @(
            Get-NetTCPConnection -State Listen -LocalPort $gdbPort -ErrorAction Stop |
                Where-Object { $_.LocalAddress -in @('0.0.0.0', '127.0.0.1', '::', '::1') } |
                Select-Object -First 1
        )
        if ($connection.Count -eq 0) { return $null }
        return [int]$connection[0].OwningProcess
    }
    catch {
        return $null
    }
}

function Get-TcpPortOwnerDescription([int]$ProcessId) {
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($process) { return "$($process.Name) (PID $ProcessId)" }
    }
    catch {}
    return "PID $ProcessId"
}

function Start-JLinkServer {
    if (-not (Test-Path -LiteralPath $jlinkPath -PathType Leaf)) {
        throw "J-Link GDB Server was not found: $jlinkPath"
    }

    $existingOwner = Get-TcpPortOwner
    if ($null -ne $existingOwner) {
        throw "J-Link GDB Server port $gdbPort is already in use by $(Get-TcpPortOwnerDescription $existingOwner). Stop the existing shared session before reconnecting."
    }

    $arguments = @($session.JLinkArguments | ForEach-Object { [string]$_ })
    if ($arguments.Count -eq 0) {
        $arguments = @(
            '-nogui',
            '-nosinglerun',
            '-CPU', [string]$session.JLinkCpu,
            '-if', [string]$session.HardwareInterface,
            '-speed', [string]$session.JLinkSpeedKHz,
            '-port', [string]$gdbPort,
            '-LocalhostOnly'
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$session.JLinkDevice)) {
            $arguments = @('-nogui', '-nosinglerun', '-device', [string]$session.JLinkDevice,
                '-if', [string]$session.HardwareInterface,
                '-speed', [string]$session.JLinkSpeedKHz, '-port', [string]$gdbPort, '-LocalhostOnly')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$session.JLinkSerialNumber)) {
            $arguments += @('-select', "USB=$([string]$session.JLinkSerialNumber)")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$session.JLinkJtagConfig)) {
            $arguments += @('-jtagconf', [string]$session.JLinkJtagConfig)
        }
    }

    Write-Event "JLINK_START interface=$([string]$session.HardwareInterface) cpu=$([string]$session.JLinkCpu) device=$([string]$session.TargetDevice) speed=$([string]$session.JLinkSpeedKHz)kHz port=$gdbPort"
    $script:jlinkProcess = Start-Process -FilePath $jlinkPath `
        -ArgumentList $arguments `
        -WorkingDirectory ([string]$session.ProjectRoot) `
        -RedirectStandardOutput ([string]$session.JLinkStdoutPath) `
        -RedirectStandardError ([string]$session.JLinkStderrPath) `
        -WindowStyle Hidden -PassThru
    $script:jlinkProcessId = [int]$script:jlinkProcess.Id
    Write-Status "STARTING;jlinkPid=$($script:jlinkProcessId)"

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $script:jlinkProcess.Refresh()
        if ($script:jlinkProcess.HasExited) {
            $detail = @(
                (Read-ChildLog ([string]$session.JLinkStderrPath)),
                (Read-ChildLog ([string]$session.JLinkStdoutPath))
            ) | Where-Object { $_ } | Select-Object -First 1
            if (-not $detail) { $detail = "J-Link GDB Server exited with code $($script:jlinkProcess.ExitCode)." }
            throw $detail
        }
        $portOwner = Get-TcpPortOwner
        if ($portOwner -eq $script:jlinkProcess.Id) {
            Write-Event "JLINK_READY pid=$($script:jlinkProcess.Id) port=$gdbPort"
            return
        }
        if ($null -ne $portOwner) {
            throw "J-Link GDB Server port $gdbPort was claimed by $(Get-TcpPortOwnerDescription $portOwner); refusing to connect to an unrelated process."
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for J-Link GDB Server on $gdbHost`:$gdbPort."
}

function Start-Gdb {
    if (-not (Test-Path -LiteralPath $gdbPath -PathType Leaf)) {
        throw "arm-none-eabi-gdb was not found: $gdbPath"
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gdbPath
    $startInfo.WorkingDirectory = [string]$session.ProjectRoot
    $startInfo.Arguments = ConvertTo-ProcessArgumentString @('--interpreter=mi2', '--nx', '--quiet')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $script:gdbProcess = New-Object Diagnostics.Process
    $script:gdbProcess.StartInfo = $startInfo
    # .NET Framework creates StandardInput using Console.InputEncoding and may emit its BOM immediately.
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    $started = $script:gdbProcess.Start()
    if (-not $started) { throw 'GDB process failed to start.' }
    if ($script:gdbProcess.HasExited) {
        throw "GDB exited immediately with code $($script:gdbProcess.ExitCode)."
    }

    # Do not use DataReceivedEventHandler here. PowerShell executes that
    # callback on a thread-pool thread without a reliable runspace, which can
    # surface as a null-valued-expression error. ReadLineAsync is polled from
    # the backend's main runspace instead.
    $script:gdbOutputReader = $script:gdbProcess.StandardOutput
    $script:gdbErrorReader = $script:gdbProcess.StandardError
    if ($null -eq $script:gdbOutputReader -or $null -eq $script:gdbErrorReader) {
        throw 'GDB MI output streams are unavailable.'
    }
    $script:gdbOutputReadTask = $script:gdbOutputReader.ReadLineAsync()
    $script:gdbErrorReadTask = $script:gdbErrorReader.ReadLineAsync()
    Write-Event "GDB_START path=$gdbPath"
}

function Pump-GdbOutput {
    while ($null -ne $script:gdbOutputReadTask -and $script:gdbOutputReadTask.IsCompleted) {
        $task = $script:gdbOutputReadTask
        $script:gdbOutputReadTask = $null
        if ($task.IsFaulted) {
            $detail = if ($task.Exception) { $task.Exception.Message } else { 'unknown read error' }
            throw "GDB stdout reader failed: $detail"
        }
        if ($task.IsCanceled) { throw 'GDB stdout reader was canceled.' }
        $line = $task.Result
        if ($null -eq $line) { return }
        $script:gdbOutputQueue.Enqueue($line)
        $script:gdbOutputReadTask = $script:gdbOutputReader.ReadLineAsync()
    }
}

function Pump-GdbError {
    while ($null -ne $script:gdbErrorReadTask -and $script:gdbErrorReadTask.IsCompleted) {
        $task = $script:gdbErrorReadTask
        $script:gdbErrorReadTask = $null
        if ($task.IsFaulted) {
            $detail = if ($task.Exception) { $task.Exception.Message } else { 'unknown read error' }
            throw "GDB stderr reader failed: $detail"
        }
        if ($task.IsCanceled) { throw 'GDB stderr reader was canceled.' }
        $line = $task.Result
        if ($null -eq $line) { return }
        $script:gdbErrorQueue.Enqueue($line)
        $script:gdbErrorReadTask = $script:gdbErrorReader.ReadLineAsync()
    }
}

function Pump-GdbStreams {
    Pump-GdbOutput
    Pump-GdbError
}

function Process-MiLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    if ($Line -match '^\*running') {
        $script:targetState = 'RUNNING'
        return
    }

    if ($Line -match '^\*stopped') {
        Write-Event ("GDB_STOP_RECORD $Line")
        $reason = if ($Line -match 'reason="([^"]+)"') { $Matches[1] } else { 'unknown' }
        $breakpointId = if ($Line -match 'bkptno="([^"]+)"') { $Matches[1] } else { '' }
        $pc = if ($Line -match 'frame=.*?addr="([^"]+)"') { $Matches[1] } else { '' }
        $script:targetState = 'HALTED'

        if ($script:manualStopPending) {
            Write-Event "TARGET_SUSPENDED PC=$pc reason=$reason"
            $script:manualStopPending = $false
        }
        elseif ($reason -eq 'breakpoint-hit') {
            $specification = if ($script:breakpoints.Contains($breakpointId)) { $script:breakpoints[$breakpointId] } else { '' }
            Write-Event "BREAKPOINT_HIT id=$breakpointId spec=$specification PC=$pc"
        }
        elseif ($reason -notin @('end-stepping-range', 'function-finished')) {
            Write-Event "TARGET_HALTED PC=$pc reason=$reason"
        }
        return
    }

    if ($Line -match '^=thread-group-exited') {
        $script:targetState = 'DISCONNECTED'
        Write-Event 'TARGET_DISCONNECTED'
    }
}

function Drain-MiQueue {
    if ($null -eq $script:gdbOutputQueue -or $null -eq $script:gdbErrorQueue) {
        throw 'GDB MI output queues are unavailable.'
    }
    Pump-GdbStreams
    $line = $null
    while ($script:gdbOutputQueue.TryDequeue([ref]$line)) {
        Process-MiLine $line
        $line = $null
    }
    while ($script:gdbErrorQueue.TryDequeue([ref]$line)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Event "GDB_ERROR $line" }
        $line = $null
    }
}

function Get-MiMessage([string]$Record) {
    if ($Record -match 'msg="((?:\\.|[^"])*)"') {
        return ConvertFrom-MiString $Matches[1]
    }
    return Get-CleanText $Record
}

function Invoke-MiCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [ValidateRange(500, 120000)]
        [int]$TimeoutMs = 10000,
        [switch]$AllowFailure
    )

    if ($null -eq $script:gdbProcess -or $script:gdbProcess.HasExited) {
        throw 'GDB process is not running.'
    }

    Drain-MiQueue
    $script:miToken++
    $token = $script:miToken
    $lineToSend = "$token$Command"
    $standardInput = $script:gdbProcess.StandardInput
    if ($null -eq $standardInput) { throw 'GDB standard input is unavailable.' }
    Write-Event "GDB_MI_SEND token=$token command=$Command"
    $standardInput.WriteLine($lineToSend)
    $standardInput.Flush()

    $record = $null
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Pump-GdbStreams
        $line = $null
        while ($script:gdbOutputQueue.TryDequeue([ref]$line)) {
            Process-MiLine $line
            if ($line -match "^$token\^(?:done|connected|error|running|exit)") {
                $record = $line
                break
            }
            $line = $null
        }
        if ($null -ne $record) { break }
        while ($script:gdbErrorQueue.TryDequeue([ref]$line)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Event "GDB_ERROR $line" }
            $line = $null
        }
        if ($script:gdbProcess.HasExited) {
            throw "GDB exited with code $($script:gdbProcess.ExitCode) while executing: $Command"
        }
        Start-Sleep -Milliseconds 10
    }

    if ($null -eq $record) {
        throw "Timed out waiting for GDB response to: $Command"
    }

    $succeeded = $record -match "^$token\^(?:done|connected|running|exit)"
    if (-not $succeeded -and -not $AllowFailure) {
        throw "GDB command failed: $(Get-MiMessage $record)"
    }

    return [pscustomobject]@{
        Token = $token
        Record = $record
        Succeeded = $succeeded
        Message = Get-MiMessage $record
    }
}

function Get-MiValue([string]$Record) {
    if ($Record -match 'value="((?:\\.|[^"])*)"') {
        return ConvertFrom-MiString $Matches[1]
    }
    return "ERROR($(Get-MiMessage $Record))"
}

function Test-TargetHalted {
    if ($script:targetState -eq 'HALTED') { return $true }
    Write-Event 'COMMAND_REJECTED target-is-running-or-disconnected; click Suspend and retry.'
    return $false
}

function Read-Expression([string]$Expression) {
    if (-not (Test-TargetHalted)) {
        Write-Event "READ $Expression=ERROR(Target is not halted; click Suspend first.)"
        return 'ERROR(Target is not halted; click Suspend first.)'
    }
    $miExpression = ConvertTo-MiString $Expression
    $reply = Invoke-MiCommand "-data-evaluate-expression `"$miExpression`"" -AllowFailure
    if ($reply.Succeeded) {
        $value = Get-MiValue $reply.Record
    }
    else {
        $value = "ERROR($($reply.Message))"
    }
    Write-Event "READ $Expression=$value"
    return $value
}

function Convert-BreakpointSpecification([string]$Specification) {
    $value = $Specification.Trim()
    if ($value.StartsWith('@')) {
        return '*' + $value.Substring(1).Trim()
    }
    return $value
}

function Add-Breakpoint([string]$Specification) {
    if (-not (Test-TargetHalted)) {
        throw 'Target must be halted before adding a breakpoint.'
    }
    $gdbSpecification = Convert-BreakpointSpecification $Specification
    $escaped = ConvertTo-MiString $gdbSpecification
    $reply = Invoke-MiCommand "-break-insert -f `"$escaped`"" -AllowFailure
    if (-not $reply.Succeeded) { throw $reply.Message }
    if ($reply.Record -notmatch 'number="([^"]+)"') { throw 'GDB did not return a breakpoint number.' }
    $id = $Matches[1]
    $script:breakpoints[$id] = $Specification
    Write-Event "BREAKPOINT_ADDED id=$id $Specification"
}

function Remove-Breakpoint([string]$Id) {
    if ($Id -notmatch '^[0-9]+(?:\.[0-9]+)?$') { throw "Invalid breakpoint id: $Id" }
    $reply = Invoke-MiCommand "-break-delete $Id" -AllowFailure
    if (-not $reply.Succeeded) { throw $reply.Message }
    if ($script:breakpoints.Contains($Id)) { $script:breakpoints.Remove($Id) }
    Write-Event "BREAKPOINT_REMOVED id=$Id"
}

function Snapshot-Watches {
    if ($script:watchExpressions.Count -eq 0) {
        Write-Event 'SNAPSHOT (no watch expressions)'
        return
    }
    if (-not (Test-TargetHalted)) {
        Write-Event 'SNAPSHOT_SKIPPED target-is-running-or-disconnected'
        return
    }
    $values = foreach ($expression in $script:watchExpressions) {
        $miExpression = ConvertTo-MiString $expression
        $reply = Invoke-MiCommand "-data-evaluate-expression `"$miExpression`"" -AllowFailure
        $value = if ($reply.Succeeded) { Get-MiValue $reply.Record } else { "ERROR($($reply.Message))" }
        "$expression=$value"
    }
    Write-Event ("SNAPSHOT " + ($values -join ';'))
}

function Stop-Children {
    if ($null -ne $script:gdbProcess) {
        try {
            if (-not $script:gdbProcess.HasExited) {
                try {
                    $script:gdbProcess.StandardInput.WriteLine("$($script:miToken + 1)-gdb-exit")
                    $script:gdbProcess.StandardInput.Flush()
                }
                catch {}
                if (-not $script:gdbProcess.WaitForExit(3000)) {
                    $script:gdbProcess.Kill()
                    $script:gdbProcess.WaitForExit(1000)
                }
            }
        }
        catch {}
        $script:gdbOutputReader = $null
        $script:gdbErrorReader = $null
        $script:gdbOutputReadTask = $null
        $script:gdbErrorReadTask = $null
        $script:gdbProcess.Dispose()
        $script:gdbProcess = $null
    }
    $jlinkPid = $script:jlinkProcessId
    if ($null -eq $jlinkPid -and $null -ne $script:jlinkProcess) {
        try { $jlinkPid = [int]$script:jlinkProcess.Id }
        catch { $jlinkPid = $null }
    }
    if ($null -ne $jlinkPid) {
        try {
            $process = Get-Process -Id $jlinkPid -ErrorAction Stop
            if ($process.ProcessName -ieq 'JLinkGDBServerCL') {
                Stop-Process -Id $jlinkPid -Force
            }
        }
        catch {}
    }
    $script:jlinkProcess = $null
    $script:jlinkProcessId = $null
}

function Restart-Target {
    if ($script:targetState -notin @('HALTED', 'RUNNING')) { throw 'Restart requires a connected target.' }
    Write-Event 'RESTART START mode=reset-and-halt'
    try {
        if ($script:targetState -eq 'RUNNING') {
            [void](Invoke-MiCommand '-exec-interrupt')
            $deadline = (Get-Date).AddSeconds(5)
            while ($script:targetState -ne 'HALTED' -and (Get-Date) -lt $deadline) {
                Drain-MiQueue
                Start-Sleep -Milliseconds 20
            }
            if ($script:targetState -ne 'HALTED') { throw 'Target did not halt before restart.' }
        }
        $script:targetState = 'RESTARTING'
        Publish-Status
        [void](Invoke-MiCommand '-interpreter-exec console "monitor reset"' -TimeoutMs 30000)
        [void](Invoke-MiCommand '-interpreter-exec console "monitor halt"')
        $reply = Invoke-MiCommand '-thread-info'
        if ($reply.Record -notmatch 'state="stopped"' -or $reply.Record -match 'state="running"') { throw 'Restart did not confirm a stopped thread.' }
        $script:targetState = 'HALTED'
        $pc = Invoke-MiCommand '-data-evaluate-expression "$pc"'
        Write-Event ("RESTART OK target=halted PC=" + (Get-MiValue $pc.Record))
        Publish-Status
    }
    catch {
        $script:targetState = 'UNKNOWN'
        Write-Event ("RESTART ERROR " + (Get-CleanText $_.Exception.Message))
        Publish-Status
        throw
    }
}

function Execute-DebugCommand([string]$Command) {
    $text = $Command.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $upper = $text.ToUpperInvariant()

    if ($upper -eq 'RESTART') {
        Restart-Target
        return
    }

    if ($upper -eq 'RESUME') {
        $reply = Invoke-MiCommand '-exec-continue' -AllowFailure
        if (-not $reply.Succeeded) { throw $reply.Message }
        Write-Event 'RESUME OK'
        return
    }

    if ($upper -eq 'SUSPEND') {
        if ($script:targetState -eq 'HALTED') {
            Write-Event 'SUSPEND SKIPPED already-halted'
            return
        }
        $script:manualStopPending = $true
        $reply = Invoke-MiCommand '-exec-interrupt' -AllowFailure
        if (-not $reply.Succeeded) {
            $script:manualStopPending = $false
            throw $reply.Message
        }
        Write-Event 'SUSPEND REQUESTED'
        return
    }

    if ($upper -eq 'SNAPSHOT') {
        Snapshot-Watches
        return
    }

    if ($upper -eq 'RECONNECT') {
        if ($script:targetState -in @('RUNNING', 'HALTED')) {
            Write-Event 'RECONNECT SKIPPED already-connected'
            return
        }
        if ($null -eq $script:jlinkProcess -or $script:jlinkProcess.HasExited) {
            throw 'J-Link GDB Server is not running; start a new shared session.'
        }
        $reply = Invoke-MiCommand "-target-select remote $gdbHost`:$gdbPort" -AllowFailure
        if (-not $reply.Succeeded) { throw $reply.Message }
        $script:targetState = 'HALTED'
        Write-Event 'RECONNECT OK'
        return
    }

    if ($upper -eq 'STOP') {
        # Close the remote connection before disposing either process. Never interrupt here.
        Write-Event 'DETACH REQUESTED mode=continue'
        if ($script:targetState -eq 'HALTED') {
            [void](Invoke-MiCommand '-exec-continue')
        }
        elseif ($script:targetState -ne 'RUNNING') { throw 'Cannot release target with unknown execution state.' }
        $detachCommand = '-target-disconnect'
        $reply = Invoke-MiCommand $detachCommand -AllowFailure
        if (-not $reply.Succeeded) { throw "Detach failed; session retained: $($reply.Message)" }
        $script:targetState = 'DISCONNECTED'
        Write-Event 'DETACH OK target=released'
        Write-Status 'STOPPING'
        $script:keepRunning = $false
        return
    }

    if ($upper.StartsWith('WATCH ')) {
        $watchText = $text.Substring(6).Trim()
        $script:watchExpressions = @(
            $watchText.Split(';') |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ } |
                Select-Object -Unique
        )
        Write-Event ("WATCH " + ($script:watchExpressions -join ';'))
        return
    }

    if ($upper.StartsWith('READ ')) {
        $expression = $text.Substring(5).Trim()
        if (-not $expression) { throw 'READ command requires an expression.' }
        [void](Read-Expression $expression)
        return
    }

    if ($upper.StartsWith('SET ')) {
        if (-not (Test-TargetHalted)) { throw 'Target is not halted; click Suspend before writing an expression.' }
        $assignment = $text.Substring(4).Trim()
        $equalsIndex = $assignment.IndexOf('=')
        if ($equalsIndex -le 0 -or $equalsIndex -ge ($assignment.Length - 1)) {
            throw 'SET command requires the form SET expression=value.'
        }
        $left = $assignment.Substring(0, $equalsIndex).Trim()
        $right = $assignment.Substring($equalsIndex + 1).Trim()
        $miAssignment = ConvertTo-MiString "$left = $right"
        $reply = Invoke-MiCommand "-data-evaluate-expression `"$miAssignment`"" -AllowFailure
        if (-not $reply.Succeeded) { throw $reply.Message }
        $readback = Read-Expression $left
        Write-Event "SET $left=$right readback=$readback"
        return
    }

    if ($upper.StartsWith('BREAKADD ')) {
        $specification = $text.Substring(9).Trim()
        if (-not $specification) { throw 'BREAKADD command requires a source location or @address.' }
        Add-Breakpoint $specification
        return
    }

    if ($upper.StartsWith('BREAKREMOVE ')) {
        Remove-Breakpoint ($text.Substring(12).Trim())
        return
    }

    throw "Unknown command: $text"
}

try {
    New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null
    Write-Status 'STARTING'
    Write-Event 'STARTING backend=JLinkGdbServer-GdbMi'

    Start-JLinkServer
    Publish-Status
    Start-Gdb

    [void](Invoke-MiCommand ("-file-exec-and-symbols `"$(ConvertTo-MiString $programPath)`""))
    [void](Invoke-MiCommand '-gdb-set confirm off' -AllowFailure)
    [void](Invoke-MiCommand '-gdb-set pagination off' -AllowFailure)
    $asyncReply = Invoke-MiCommand '-gdb-set mi-async on' -AllowFailure
    if (-not $asyncReply.Succeeded) {
        [void](Invoke-MiCommand '-gdb-set target-async on' -AllowFailure)
    }
    $connectReply = Invoke-MiCommand "-target-select remote $gdbHost`:$gdbPort" -AllowFailure
    if (-not $connectReply.Succeeded) { throw $connectReply.Message }
    $script:targetState = 'HALTED'
    Write-Event "CONNECT OK remote=$gdbHost`:$gdbPort program=$programPath"

    if ([bool]$session.LoadProgram) {
        $downloadReply = Invoke-MiCommand '-target-download' -AllowFailure -TimeoutMs 120000
        if (-not $downloadReply.Succeeded) { throw "Program download failed: $($downloadReply.Message)" }
        Write-Event "LOADPROGRAM OK $programPath"
    }

    foreach ($specification in @($session.Breakpoints | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
        try { Add-Breakpoint $specification }
        catch { Write-Event "BREAKPOINT_ERROR spec=$specification message=$($_.Exception.Message)" }
    }

    if ([bool]$session.RestartTarget) {
        $runReply = Invoke-MiCommand '-exec-run' -AllowFailure
        if (-not $runReply.Succeeded) { throw "Target restart failed: $($runReply.Message)" }
        Write-Event 'RESTART REQUESTED'
    }
    elseif ([bool]$session.ResumeTarget) {
        $resumeReply = Invoke-MiCommand '-exec-continue' -AllowFailure
        if (-not $resumeReply.Succeeded) { throw "Target resume failed: $($resumeReply.Message)" }
        Write-Event 'GO OK source=IAR_BREAK_RESET_GO'
    }
    elseif ([bool]$session.LoadProgram -and $script:targetState -ne 'HALTED') {
        $script:manualStopPending = $true
        [void](Invoke-MiCommand '-exec-interrupt' -AllowFailure)
    }

    Publish-Status
    if ($script:watchExpressions.Count -gt 0) {
        Write-Event ("WATCH_INITIAL " + ($script:watchExpressions -join ';'))
    }

    while ($script:keepRunning) {
        Drain-MiQueue
        if ($script:gdbProcess.HasExited) {
            throw "GDB exited unexpectedly with code $($script:gdbProcess.ExitCode)."
        }
        if ($script:jlinkProcess.HasExited -and $script:targetState -ne 'DISCONNECTED') {
            throw "J-Link GDB Server exited unexpectedly with code $($script:jlinkProcess.ExitCode)."
        }

        $commandFiles = @()
        if (Test-Path -LiteralPath $commandDirectory -PathType Container) {
            $commandFiles = @(Get-ChildItem -LiteralPath $commandDirectory -Filter '*.cmd' -File | Sort-Object Name)
        }
        foreach ($commandFile in $commandFiles) {
            try {
                $command = (Get-Content -Raw -LiteralPath $commandFile.FullName).Trim()
                Remove-Item -LiteralPath $commandFile.FullName -Force
                Execute-DebugCommand $command
            }
            catch {
                $message = Get-CleanText $_.Exception.Message
                Write-Event "COMMAND_ERROR $message"
            }
            if (-not $script:keepRunning) { break }
        }

        if ($script:targetState -ne $script:previousState) {
            Write-Event "STATE $script:targetState"
            $script:previousState = $script:targetState
        }
        Publish-Status
        Start-Sleep -Milliseconds 200
    }
}
catch {
    $script:fatalError = $true
    $message = Get-CleanText $_.Exception.Message
    $safeMessage = $message -replace ';', ' '
    $location = ''
    try {
        if ($null -ne $_.InvocationInfo) {
            $lineNumber = $_.InvocationInfo.ScriptLineNumber
            $sourceLine = Get-CleanText $_.InvocationInfo.Line
            $location = " line=$lineNumber source=$sourceLine"
        }
    }
    catch {}
    $jlinkPart = if ($null -ne $script:jlinkProcessId) { ";jlinkPid=$($script:jlinkProcessId)" } else { '' }
    Write-Status "ERROR;message=$safeMessage$jlinkPart"
    Write-Event "FATAL $message$location"
}
finally {
    Stop-Children
    if (-not $script:fatalError) {
        Write-Status 'STOPPED'
        Write-Event 'STOPPED'
    }
}

if ($script:fatalError) { exit 1 }
exit 0
