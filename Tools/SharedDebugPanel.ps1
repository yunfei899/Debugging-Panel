[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Data

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$settingsPath = Join-Path $PSScriptRoot 'SharedDebugConfig.ps1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Shared debug config does not exist: $settingsPath"
}
$settings = & $settingsPath -ProjectRoot $ProjectRoot
$currentSessionPath = Join-Path ([string]$settings.RuntimeDirectory) 'current-session.json'
$launcherPath = Join-Path $PSScriptRoot 'StartSharedDebug.ps1'
$buildScriptPath = Join-Path $PSScriptRoot 'BuildAndDownload.ps1'
$buildStatusPath = Join-Path ([string]$settings.RuntimeDirectory) 'build-status.txt'
$downloadStatusPath = Join-Path ([string]$settings.RuntimeDirectory) 'download-status.txt'
$script:session = $null
$script:lastSessionStamp = $null
$script:lastStopEvent = ''
$script:lastBreakpointError = ''
$script:lastDownloadStatus = ''
$script:downloadWasRunning = $false
$script:downloadStartStamp = 0
$script:pendingBreakpointSpec = ''
$script:pendingBreakpointLineCount = 0
$script:pendingReads = @{}
$script:pendingWrites = @{}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="IAR/J-Link 共享调试面板" Width="920" Height="730" MinWidth="800" MinHeight="600"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" BorderBrush="#888" BorderThickness="1" CornerRadius="4" Padding="8">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
          <TextBlock Name="StateText" Text="NO SESSION" FontSize="18" FontWeight="Bold"/>
          <TextBlock Name="TargetText" Text="目标：未连接" FontSize="13" Margin="0,4,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="BackendText" Text="后台：未启动" FontSize="13" Margin="0,2,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="StopText" Text="最近停止：无" FontSize="13" Margin="0,4,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="BuildText" Text="编译：未开始" FontSize="13" Margin="0,2,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="DownloadText" Text="下载：未开始" FontSize="13" Margin="0,2,12,0" TextWrapping="Wrap"/>
        </StackPanel>
        <WrapPanel Grid.Row="1" HorizontalAlignment="Right" Margin="0,8,0,0">
          <Button Name="BuildButton" Content="IAR 编译下载/BRG" Margin="5,0" Padding="16,5" ToolTip="编译、下载并执行 Break → Reset → Go"/>
          <Button Name="ConnectButton" Content="下载并调试" Margin="5,0" Padding="16,5"/>
          <Button Name="SuspendButton" Content="中断 Break" Margin="5,0" Padding="16,5"/>
          <Button Name="RestartButton" Content="重启 Restart" Margin="5,0" Padding="16,5" ToolTip="复位目标并保持暂停；不编译、不下载"/>
          <Button Name="ResumeButton" Content="运行 Go" Margin="5,0" Padding="16,5"/>
          <Button Name="SnapshotButton" Content="刷新变量" Margin="5,0" Padding="16,5"/>
          <Button Name="StopButton" Content="断开调试" Margin="5,0" Padding="16,5"/>
        </WrapPanel>
      </Grid>
    </Border>

    <GroupBox Grid.Row="1" Header="变量监视与读写" Margin="0,10,0,0">
      <Grid Margin="6">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="105"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="250"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <DockPanel Grid.Row="0" Grid.Column="0" Margin="0,0,0,4">
          <Button Name="WatchButton" Content="应用监视" DockPanel.Dock="Right" Padding="7,1" Margin="6,0,0,0"/>
          <TextBlock Text="监视表达式（每行一个）" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox Name="WatchBox" Grid.Row="1" Grid.Column="0" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
        <DataGrid Name="ExpressionGrid" Grid.Row="0" Grid.RowSpan="2" Grid.Column="2"
                  AutoGenerateColumns="False" CanUserAddRows="True" CanUserDeleteRows="True"
                  HeadersVisibility="Column" GridLinesVisibility="All" SelectionMode="Single" SelectionUnit="FullRow"
                  FontFamily="Consolas" Margin="0,0,8,0">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Expression" Binding="{Binding Expression, UpdateSourceTrigger=PropertyChanged}" Width="2*"/>
            <DataGridTextColumn Header="Value" Binding="{Binding Value, UpdateSourceTrigger=PropertyChanged}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="0" Grid.RowSpan="2" Grid.Column="3" VerticalAlignment="Center">
          <Button Name="ReadButton" Content="读取全部" Padding="10,4" Margin="0,0,0,6"/>
          <Button Name="SetButton" Content="写入选中" Padding="10,4"/>
        </StackPanel>
      </Grid>
    </GroupBox>

    <GroupBox Grid.Row="2" Header="当前断点" Margin="0,10,0,0">
      <Grid Margin="6">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="70"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="100"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="BreakpointBox" Grid.Column="0" VerticalContentAlignment="Center" ToolTip="file.c:line 或 @0x地址"/>
        <Button Name="AddBreakpointButton" Grid.Column="1" Content="添加" Margin="8,0" Padding="16,4"/>
        <TextBox Name="BreakpointIdBox" Grid.Column="2" ToolTip="Breakpoint ID" VerticalContentAlignment="Center"/>
        <Button Name="RemoveBreakpointButton" Grid.Column="3" Content="删除 ID" Margin="8,0,0,0" Padding="12,4"/>
        <ListBox Name="BreakpointListBox" Grid.Row="1" Grid.ColumnSpan="4" Margin="0,7,0,0" FontFamily="Consolas"/>
      </Grid>
    </GroupBox>

    <GroupBox Grid.Row="3" Header="事件记录" Margin="0,10,0,0">
      <TextBox Name="EventsBox" Margin="6" IsReadOnly="True" FontFamily="Consolas" TextWrapping="NoWrap"
               HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"/>
    </GroupBox>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = @(
    'StateText', 'TargetText', 'BackendText', 'StopText', 'BuildText', 'DownloadText',
    'BuildButton', 'ConnectButton', 'ResumeButton', 'RestartButton', 'SuspendButton', 'SnapshotButton', 'StopButton',
    'WatchBox', 'WatchButton', 'ExpressionGrid', 'ReadButton', 'SetButton', 'BreakpointBox',
    'AddBreakpointButton', 'BreakpointIdBox', 'RemoveBreakpointButton', 'BreakpointListBox', 'EventsBox'
)
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }

$WatchBox.Text = @($settings.DefaultWatch) -join "`r`n"
$expressionTable = New-Object System.Data.DataTable
[void]$expressionTable.Columns.Add('Expression', [string])
[void]$expressionTable.Columns.Add('Value', [string])
$ExpressionGrid.ItemsSource = $expressionTable.DefaultView

function Read-Utf8Text([string]$Path) {
    return Get-Content -Raw -LiteralPath $Path -Encoding UTF8
}

function Read-Utf8Lines([string]$Path) {
    return @(Get-Content -LiteralPath $Path -Encoding UTF8)
}

function Update-Session {
    if (-not (Test-Path -LiteralPath $currentSessionPath -PathType Leaf)) {
        $script:session = $null
        return
    }
    $stamp = (Get-Item -LiteralPath $currentSessionPath).LastWriteTimeUtc.Ticks
    if ($stamp -ne $script:lastSessionStamp) {
        try {
            $script:session = Read-Utf8Text $currentSessionPath | ConvertFrom-Json
            $script:lastSessionStamp = $stamp
        }
        catch { $script:session = $null }
    }
}

function Send-DebugCommand([string]$Command) {
    Update-Session
    if ($null -eq $script:session -or -not $script:session.CommandDirectory) {
        [System.Windows.MessageBox]::Show('没有可用的共享调试会话，请先点击“连接”。', '共享调试') | Out-Null
        return $false
    }
    $directory = [string]$script:session.CommandDirectory
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $id = '{0:yyyyMMddHHmmssfffffff}-{1}-{2}' -f (Get-Date), $PID, ([Guid]::NewGuid().ToString('N'))
    $temporaryPath = Join-Path $directory "$id.tmp"
    $commandPath = Join-Path $directory "$id.cmd"
    [IO.File]::WriteAllText($temporaryPath, $Command.Trim(), [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $temporaryPath -Destination $commandPath
    return $true
}

function Commit-ExpressionGrid {
    [void]$ExpressionGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true)
    [void]$ExpressionGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row, $true)
}

function Set-ExpressionValue([string]$Expression, [string]$Value) {
    foreach ($row in $expressionTable.Rows) {
        if ($row.RowState -ne [System.Data.DataRowState]::Deleted -and [string]$row['Expression'] -eq $Expression) {
            $row['Value'] = $Value
        }
    }
}

function Get-SessionEvents {
    if ($null -eq $script:session -or -not $script:session.EventsPath -or
        -not (Test-Path -LiteralPath $script:session.EventsPath -PathType Leaf)) { return @() }
    return Read-Utf8Lines $script:session.EventsPath
}

function Refresh-Display {
    $downloadState = ''
    $downloadActive = $false
    if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        try {
            $downloadStatus = (Read-Utf8Text $downloadStatusPath).Trim()
            $downloadStatusStamp = (Get-Item -LiteralPath $downloadStatusPath).LastWriteTimeUtc.Ticks
            $downloadState = ($downloadStatus -split ';', 2)[0]
            $DownloadText.Text = "下载：$downloadState"
            $downloadActive = $downloadState -in @('BUILDING', 'STOPPING_SESSION', 'DOWNLOADING')
            if ($downloadActive) { $script:downloadWasRunning = $true }
            if ($script:downloadWasRunning -and ($downloadState -eq 'SUCCESS' -or $downloadState -eq 'FAILED') -and
                $downloadStatusStamp -gt $script:downloadStartStamp -and
                $downloadStatus -ne $script:lastDownloadStatus) {
                $script:lastDownloadStatus = $downloadStatus
                $script:downloadWasRunning = $false
                $title = if ($downloadState -eq 'SUCCESS') { '编译并下载成功' } else { '编译/下载失败' }
                $dialogMessage = if ($downloadStatus -match ';message=(.*)$') { $Matches[1] } else { $downloadStatus }
                [System.Windows.MessageBox]::Show($dialogMessage, $title) | Out-Null
            }
        }
        catch {}
    }
    else { $DownloadText.Text = '下载：未开始' }

    if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        try {
            $buildStatus = (Read-Utf8Text $buildStatusPath).Trim()
            $buildState = ($buildStatus -split ';', 2)[0]
            $BuildText.Text = "编译：$buildState"
            $BuildButton.IsEnabled = -not $buildStatus.StartsWith('BUILDING') -and -not $downloadActive
        }
        catch {}
    }

    Update-Session
    if ($null -eq $script:session) {
        $StateText.Text = 'NO SESSION'
        $StateText.Foreground = [Windows.Media.Brushes]::Gray
        $TargetText.Text = "目标：$([string]$settings.TargetDevice) / $([string]$settings.HardwareInterface)"
        $BackendText.Text = '后台：未启动'
        $ConnectButton.Content = '下载并调试'
        return
    }

    $status = if (Test-Path -LiteralPath $script:session.StatusPath -PathType Leaf) {
        try { (Read-Utf8Text $script:session.StatusPath).Trim() } catch { '' }
    } else { '' }
    $sessionProcess = if ($script:session.ProcessId) {
        Get-Process -Id ([int]$script:session.ProcessId) -ErrorAction SilentlyContinue
    } else { $null }
    $statusState = if ($status) { ($status -split ';', 2)[0] } else { '' }
    $state = if ($statusState -in @('ERROR', 'DISCONNECTED')) { $statusState }
        elseif (-not $sessionProcess) { 'STOPPED' }
        elseif ($statusState) { $statusState }
        else { 'STARTING' }
    $StateText.Text = $state
    $StateText.Foreground = switch ($state) {
        'RUNNING' { [Windows.Media.Brushes]::Green }
        'HALTED' { [Windows.Media.Brushes]::DarkOrange }
        'STARTING' { [Windows.Media.Brushes]::SteelBlue }
        'DISCONNECTED' { [Windows.Media.Brushes]::DarkOrange }
        default { [Windows.Media.Brushes]::Firebrick }
    }
    $TargetText.Text = "目标：$([string]$script:session.TargetDevice) / $([string]$script:session.HardwareInterface) / $([string]$script:session.GdbServerHost):$([string]$script:session.GdbServerPort)"
    $BackendText.Text = "后台：$([string]$script:session.Backend)"
    if ($state -eq 'DISCONNECTED') { $ConnectButton.Content = '下载并调试' }
    elseif ($state -in @('RUNNING', 'HALTED')) { $ConnectButton.Content = '已连接' }
    else { $ConnectButton.Content = '下载并调试' }

    $allLines = @(Get-SessionEvents)
    $lines = @($allLines | Select-Object -Last 250)

    foreach ($expression in @($script:pendingReads.Keys)) {
        $newReadLines = @($allLines | Select-Object -Skip ([int]$script:pendingReads[$expression]))
        $escapedExpression = [regex]::Escape($expression)
        $readResult = $newReadLines | Where-Object { $_ -match "\tREAD $escapedExpression=(.*)$" } | Select-Object -Last 1
        if ($readResult -and $readResult -match "\tREAD $escapedExpression=(.*)$") {
            Set-ExpressionValue $expression $Matches[1]
            $script:pendingReads.Remove($expression)
        }
    }
    foreach ($expression in @($script:pendingWrites.Keys)) {
        $newWriteLines = @($allLines | Select-Object -Skip ([int]$script:pendingWrites[$expression]))
        $escapedExpression = [regex]::Escape($expression)
        $writeResult = $newWriteLines | Where-Object { $_ -match "\tSET $escapedExpression=.* readback=(.*)$" } | Select-Object -Last 1
        if ($writeResult -and $writeResult -match "\tSET $escapedExpression=.* readback=(.*)$") {
            Set-ExpressionValue $expression $Matches[1]
            $script:pendingWrites.Remove($expression)
        }
    }

    $newEventsText = $lines -join [Environment]::NewLine
    if ($EventsBox.Text -ne $newEventsText) {
        $horizontalOffset = $EventsBox.HorizontalOffset
        $verticalOffset = $EventsBox.VerticalOffset
        $wasAtBottom = ($EventsBox.ExtentHeight - $EventsBox.ViewportHeight - $verticalOffset) -le 1
        $EventsBox.Text = $newEventsText
        if ($wasAtBottom) { $EventsBox.ScrollToEnd() }
        else { $EventsBox.ScrollToVerticalOffset($verticalOffset) }
        $EventsBox.ScrollToHorizontalOffset($horizontalOffset)
    }

    $breakpoints = [ordered]@{}
    foreach ($line in $allLines) {
        if ($line -match 'BREAKPOINT_ADDED id=([^\s]+)\s+(.+)$') { $breakpoints[$Matches[1]] = $Matches[2] }
        elseif ($line -match 'BREAKPOINT_REMOVED id=([^\s]+)') { $breakpoints.Remove($Matches[1]) }
    }

    if ($script:pendingBreakpointSpec) {
        $newBreakpointLines = @($allLines | Select-Object -Skip $script:pendingBreakpointLineCount)
        $addedSpec = [regex]::Escape($script:pendingBreakpointSpec)
        if ($newBreakpointLines | Where-Object { $_ -match "BREAKPOINT_ADDED id=[^\s]+\s+$addedSpec$" } | Select-Object -First 1) {
            if ($BreakpointBox.Text.Trim() -eq $script:pendingBreakpointSpec) { $BreakpointBox.Clear() }
            $script:pendingBreakpointSpec = ''
        }
        elseif ($newBreakpointLines | Where-Object { $_ -match "BREAKPOINT_ERROR spec=$addedSpec(?:\s|$)" } | Select-Object -First 1) {
            $script:pendingBreakpointSpec = ''
        }
    }

    $breakpointError = $lines | Where-Object { $_ -match '\tBREAKPOINT_ERROR\s' } | Select-Object -Last 1
    if ($breakpointError -and $breakpointError -ne $script:lastBreakpointError) {
        $script:lastBreakpointError = $breakpointError
        [System.Windows.MessageBox]::Show(($breakpointError -split "`t", 2)[1], '断点错误') | Out-Null
    }

    $stopEvent = $lines | Where-Object { $_ -match '\t(BREAKPOINT_HIT|TARGET_SUSPENDED|TARGET_HALTED)\s' } | Select-Object -Last 1
    if ($stopEvent) {
        $stopMessage = ($stopEvent -split "`t", 2)[1]
        $StopText.Text = "最近停止：$stopMessage"
        if ($stopMessage -match '^BREAKPOINT_HIT' -and $stopEvent -ne $script:lastStopEvent) {
            $script:lastStopEvent = $stopEvent
            [System.Windows.MessageBox]::Show($stopMessage, '命中断点') | Out-Null
        }
    }

    $items = @($breakpoints.GetEnumerator() | ForEach-Object { "ID $($_.Key)  $($_.Value)" })
    if ((@($BreakpointListBox.Items | ForEach-Object { [string]$_ }) -join "`n") -ne ($items -join "`n")) {
        $BreakpointListBox.Items.Clear()
        foreach ($item in $items) { [void]$BreakpointListBox.Items.Add($item) }
    }
}

$BuildButton.Add_Click({
    if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        if ((Read-Utf8Text $buildStatusPath).Trim().StartsWith('BUILDING')) {
            [System.Windows.MessageBox]::Show('IAR 编译已经在进行中。', '编译') | Out-Null
            return
        }
    }
    if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        $currentDownloadStatus = (Read-Utf8Text $downloadStatusPath).Trim()
        if (($currentDownloadStatus -split ';', 2)[0] -in @('BUILDING', 'STOPPING_SESSION', 'DOWNLOADING')) {
            [System.Windows.MessageBox]::Show('编译/下载操作已经在进行中。', '编译并下载') | Out-Null
            return
        }
    }
    $answer = [System.Windows.MessageBox]::Show(
        "IAR 编译成功后会使用 C-SPY 下载器和工程宏下载程序，执行 Break → Reset → Go；随后建立 J-Link/GDB 共享会话并恢复运行。该流程会复位并运行 CPU。`r`n`r`n请确认设备处于安全状态，并确认 IAR/C-SPY 没有占用同一探针。",
        'IAR 编译下载/BRG', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $BuildButton.IsEnabled = $false
    $BuildText.Text = '编译：STARTING'
    $DownloadText.Text = '下载：BUILDING'
    # 记录点击前的状态，避免把上一次的 SUCCESS/FAILED 当成本次结果。
    $script:lastDownloadStatus = if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        (Read-Utf8Text $downloadStatusPath).Trim()
    }
    else { '' }
    $script:downloadStartStamp = if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        (Get-Item -LiteralPath $downloadStatusPath).LastWriteTimeUtc.Ticks
    }
    else { 0 }
    $script:downloadWasRunning = $true
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScriptPath,
        '-ProjectRoot', $ProjectRoot, '-AllowHardware', '-AllowProgramLoad'
    ) | Out-Null
})

$ConnectButton.Add_Click({
    try {
        Update-Session
        $currentStatus = if ($script:session -and (Test-Path -LiteralPath $script:session.StatusPath)) {
            Read-Utf8Text $script:session.StatusPath
        } else { '' }
        $sessionProcess = if ($script:session -and $script:session.ProcessId) {
            Get-Process -Id ([int]$script:session.ProcessId) -ErrorAction SilentlyContinue
        } else { $null }

        if ($sessionProcess -and $currentStatus -match '^(RUNNING|HALTED|STARTING|DISCONNECTED|RESTARTING|UNKNOWN)') {
            [System.Windows.MessageBox]::Show('共享调试会话已经存在。', '共享调试') | Out-Null
        }
        else {
            $answer = [System.Windows.MessageBox]::Show(
                "下载现有 OUT（不编译），执行工程初始化并暂停进入调试。当前配置目标为 $([string]$settings.TargetDevice)、接口为 $([string]$settings.HardwareInterface)，请确认与实际线缆一致；同时确认 IAR/C-SPY Debug 已断开。",
                '下载并调试', 'YesNo', 'Warning')
            if ($answer -eq 'Yes') {
                & $launcherPath -ProjectRoot $ProjectRoot -AllowHardware -AllowProgramLoad -LoadProgram -NoPanel
            }
        }
    }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, '连接失败') | Out-Null }
})

$RestartButton.Add_Click({ [void](Send-DebugCommand 'RESTART') })
$ResumeButton.Add_Click({ [void](Send-DebugCommand 'RESUME') })
$SuspendButton.Add_Click({ [void](Send-DebugCommand 'SUSPEND') })
$SnapshotButton.Add_Click({ [void](Send-DebugCommand 'SNAPSHOT') })
$WatchButton.Add_Click({
    $watch = (($WatchBox.Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ';'
    if (Send-DebugCommand "WATCH $watch") { [void](Send-DebugCommand 'SNAPSHOT') }
})
$ReadButton.Add_Click({
    Commit-ExpressionGrid
    Update-Session
    $lineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
        @(Read-Utf8Lines $script:session.EventsPath).Count
    } else { 0 }
    $expressions = @($expressionTable.Rows | ForEach-Object { ([string]$_['Expression']).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($expressions.Count -eq 0) {
        [System.Windows.MessageBox]::Show('请先添加至少一个表达式。', '读取表达式') | Out-Null
        return
    }
    foreach ($expression in $expressions) {
        $script:pendingReads[$expression] = $lineCount
        [void](Send-DebugCommand "READ $expression")
    }
})
$SetButton.Add_Click({
    Commit-ExpressionGrid
    $selectedRow = $ExpressionGrid.SelectedItem
    if ($selectedRow -isnot [System.Data.DataRowView]) {
        [System.Windows.MessageBox]::Show('请选择一行表达式进行写入。', '写入表达式') | Out-Null
        return
    }
    $expression = ([string]$selectedRow['Expression']).Trim()
    $value = ([string]$selectedRow['Value']).Trim()
    if (-not $expression -or -not $value) {
        [System.Windows.MessageBox]::Show('选中行必须同时填写 Expression 和 Value。', '写入表达式') | Out-Null
        return
    }
    if ($expression.Contains('=')) {
        [System.Windows.MessageBox]::Show('Expression 不能包含赋值运算符。', '写入表达式') | Out-Null
        return
    }
    Update-Session
    $lineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
        @(Read-Utf8Lines $script:session.EventsPath).Count
    } else { 0 }
    $script:pendingWrites[$expression] = $lineCount
    [void](Send-DebugCommand "SET $expression=$value")
})
$AddBreakpointButton.Add_Click({
    $specification = $BreakpointBox.Text.Trim()
    if ($specification) {
        Update-Session
        $script:pendingBreakpointSpec = $specification
        $script:pendingBreakpointLineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
            @(Read-Utf8Lines $script:session.EventsPath).Count
        } else { 0 }
        [void](Send-DebugCommand "BREAKADD $specification")
    }
})
$RemoveBreakpointButton.Add_Click({
    $id = $BreakpointIdBox.Text.Trim()
    if ($id) { [void](Send-DebugCommand "BREAKREMOVE $id") }
})
$BreakpointListBox.Add_SelectionChanged({
    if ($BreakpointListBox.SelectedItem -match '^ID\s+([^\s]+)') { $BreakpointIdBox.Text = $Matches[1] }
})
$StopButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        '释放调试连接并让目标独立运行？不会主动暂停、复位或下载。',
        '断开共享调试', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { [void](Send-DebugCommand 'STOP') }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ Refresh-Display })
$timer.Start()
Refresh-Display
$window.ShowDialog() | Out-Null
