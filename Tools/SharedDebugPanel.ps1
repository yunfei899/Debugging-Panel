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
$script:pendingBreakpointSpec = ''
$script:pendingBreakpointLineCount = 0
$script:activeBreakpointIds = @()
$script:pendingReads = @{}
$script:pendingWrites = @{}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="XDS2xx &#x5171;&#x4EAB;&#x8C03;&#x8BD5;&#x9762;&#x677F;" Width="880" Height="700" MinWidth="760" MinHeight="580"
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
          <TextBlock Name="StopText" Text="&#x6700;&#x8FD1;&#x505C;&#x6B62;&#xFF1A;&#x65E0;" FontSize="13" Margin="0,4,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="BuildText" Text="&#x7F16;&#x8BD1;&#x72B6;&#x6001;&#xFF1A;&#x672A;&#x5F00;&#x59CB;" FontSize="13" Margin="0,4,12,0" TextWrapping="Wrap"/>
          <TextBlock Name="DownloadText" Text="&#x4E0B;&#x8F7D;&#x72B6;&#x6001;&#xFF1A;&#x672A;&#x5F00;&#x59CB;" FontSize="13" Margin="0,4,12,0" TextWrapping="Wrap"/>
        </StackPanel>
        <WrapPanel Grid.Row="1" HorizontalAlignment="Right" Margin="0,8,0,0">
          <Button Name="BuildButton" Content="&#x7F16;&#x8BD1;&#x5E76;&#x4E0B;&#x8F7D;" Margin="5,0" Padding="16,5"/>
          <Button Name="ConnectButton" Content="&#x8FDE;&#x63A5;" Margin="5,0" Padding="16,5"/>
          <Button Name="ResumeButton" Content="&#x7EE7;&#x7EED; Resume" Margin="5,0" Padding="16,5"/>
          <Button Name="SuspendButton" Content="&#x6682;&#x505C; Suspend" Margin="5,0" Padding="16,5"/>
          <Button Name="SnapshotButton" Content="&#x5237;&#x65B0;&#x5FEB;&#x7167;" Margin="5,0" Padding="16,5"/>
          <Button Name="StopButton" Content="&#x65AD;&#x5F00;" Margin="5,0" Padding="16,5"/>
        </WrapPanel>
      </Grid>
    </Border>

    <GroupBox Grid.Row="1" Header="&#x53D8;&#x91CF;&#x76D1;&#x89C6;&#x4E0E;&#x8BFB;&#x5199;" Margin="0,10,0,0">
      <Grid Margin="6">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="105"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="240"/>
          <ColumnDefinition Width="8"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <DockPanel Grid.Row="0" Grid.Column="0" Margin="0,0,0,4">
          <Button Name="WatchButton" Content="&#x5E94;&#x7528;&#x76D1;&#x89C6;" DockPanel.Dock="Right" Padding="7,1" Margin="6,0,0,0"/>
          <TextBlock Text="&#x76D1;&#x89C6;&#x53D8;&#x91CF;&#xFF08;&#x6BCF;&#x884C;&#x4E00;&#x4E2A;&#xFF09;" VerticalAlignment="Center"/>
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
          <Button Name="ReadButton" Content="&#x8BFB;&#x53D6;&#x5168;&#x90E8;" Padding="10,4" Margin="0,0,0,6"/>
          <Button Name="SetButton" Content="&#x5199;&#x5165;&#x9009;&#x4E2D;" Padding="10,4"/>
        </StackPanel>
      </Grid>
    </GroupBox>

    <GroupBox Grid.Row="2" Header="&#x5F53;&#x524D;&#x65AD;&#x70B9;" Margin="0,10,0,0">
      <Grid Margin="6">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="70"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="90"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="BreakpointBox" Grid.Column="0" VerticalContentAlignment="Center"/>
        <Button Name="AddBreakpointButton" Grid.Column="1" Content="&#x6DFB;&#x52A0;" Margin="8,0" Padding="16,4"/>
        <TextBox Name="BreakpointIdBox" Grid.Column="2" ToolTip="Breakpoint ID" VerticalContentAlignment="Center"/>
        <Button Name="RemoveBreakpointButton" Grid.Column="3" Content="&#x5220;&#x9664;ID" Margin="8,0,0,0" Padding="12,4"/>
        <ListBox Name="BreakpointListBox" Grid.Row="1" Grid.ColumnSpan="4" Margin="0,7,0,0" FontFamily="Consolas"/>
      </Grid>
    </GroupBox>

    <GroupBox Grid.Row="3" Header="&#x4E8B;&#x4EF6;&#x8BB0;&#x5F55;" Margin="0,10,0,0">
      <TextBox Name="EventsBox" Margin="6" IsReadOnly="True" FontFamily="Consolas" TextWrapping="NoWrap"
               HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"/>
    </GroupBox>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = @('StateText', 'StopText', 'BuildText', 'DownloadText', 'BuildButton', 'ConnectButton', 'ResumeButton', 'SuspendButton', 'SnapshotButton', 'StopButton',
    'WatchBox', 'WatchButton', 'ExpressionGrid', 'ReadButton', 'SetButton', 'BreakpointBox',
    'AddBreakpointButton', 'BreakpointIdBox', 'RemoveBreakpointButton', 'BreakpointListBox', 'EventsBox')
foreach ($name in $names) {
    Set-Variable -Name $name -Value $window.FindName($name)
}
$WatchBox.Text = @($settings.DefaultWatch) -join "`r`n"
$expressionTable = New-Object System.Data.DataTable
[void]$expressionTable.Columns.Add('Expression', [string])
[void]$expressionTable.Columns.Add('Value', [string])
$ExpressionGrid.ItemsSource = $expressionTable.DefaultView

function Update-Session {
    if (-not (Test-Path -LiteralPath $currentSessionPath -PathType Leaf)) {
        $script:session = $null
        return
    }
    $stamp = (Get-Item -LiteralPath $currentSessionPath).LastWriteTimeUtc.Ticks
    if ($stamp -ne $script:lastSessionStamp) {
        try {
            $script:session = Get-Content -Raw -LiteralPath $currentSessionPath | ConvertFrom-Json
            $script:lastSessionStamp = $stamp
        }
        catch {
            $script:session = $null
        }
    }
}

function Send-DebugCommand([string]$Command) {
    Update-Session
    if ($null -eq $script:session -or -not $script:session.CommandDirectory) {
        [System.Windows.MessageBox]::Show('No shared debug session is available. Click Connect first.', 'Shared Debug') | Out-Null
        return
    }
    $directory = [string]$script:session.CommandDirectory
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $id = '{0:yyyyMMddHHmmssfffffff}-{1}-{2}' -f (Get-Date), $PID, ([Guid]::NewGuid().ToString('N'))
    $temporaryPath = Join-Path $directory "$id.tmp"
    $commandPath = Join-Path $directory "$id.cmd"
    [IO.File]::WriteAllText($temporaryPath, $Command, [Text.Encoding]::ASCII)
    Move-Item -LiteralPath $temporaryPath -Destination $commandPath
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

function Refresh-Display {
    $downloadState = ''
    $downloadActive = $false
    if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        try {
            $downloadStatus = (Get-Content -Raw -LiteralPath $downloadStatusPath).Trim()
            $downloadState = ($downloadStatus -split ';', 2)[0]
            $DownloadText.Text = "Download: $downloadState"
            $downloadActive = $downloadState -in @('BUILDING', 'STOPPING_SESSION', 'DOWNLOADING')
            if ($downloadActive) { $script:downloadWasRunning = $true }
            if ($script:downloadWasRunning -and ($downloadState -eq 'SUCCESS' -or $downloadState -eq 'FAILED') -and $downloadStatus -ne $script:lastDownloadStatus) {
                $script:lastDownloadStatus = $downloadStatus
                $script:downloadWasRunning = $false
                $title = if ($downloadState -eq 'SUCCESS') { 'Build and download succeeded' } else { 'Build/download failed' }
                [System.Windows.MessageBox]::Show($downloadStatus, $title) | Out-Null
            }
        }
        catch {}
    }
    else {
        $DownloadText.Text = 'Download: NOT STARTED'
    }

    if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        try {
            $buildStatus = (Get-Content -Raw -LiteralPath $buildStatusPath).Trim()
            $buildState = ($buildStatus -split ';', 2)[0]
            $BuildText.Text = "Build: $buildState"
            $BuildButton.IsEnabled = -not $buildStatus.StartsWith('BUILDING') -and -not $downloadActive
        }
        catch {}
    }

    Update-Session
    if ($null -eq $script:session) {
        $StateText.Text = 'NO SESSION'
        $StateText.Foreground = [Windows.Media.Brushes]::Gray
        return
    }

    $status = ''
    if (Test-Path -LiteralPath $script:session.StatusPath -PathType Leaf) {
        try { $status = Get-Content -Raw -LiteralPath $script:session.StatusPath } catch {}
    }
    $sessionProcess = if ($script:session.ProcessId) { Get-Process -Id ([int]$script:session.ProcessId) -ErrorAction SilentlyContinue } else { $null }
    $state = if (-not $sessionProcess) { 'STOPPED' } elseif ($status) { ($status -split ';', 2)[0] } else { 'STARTING' }
    $StateText.Text = $state
    $StateText.Foreground = switch ($state) {
        'RUNNING' { [Windows.Media.Brushes]::Green }
        'HALTED' { [Windows.Media.Brushes]::DarkOrange }
        'STARTING' { [Windows.Media.Brushes]::SteelBlue }
        default { [Windows.Media.Brushes]::Firebrick }
    }
    if ($state -eq 'DISCONNECTED') {
        $ConnectButton.Content = 'Reconnect'
    }
    elseif ($state -eq 'RUNNING' -or $state -eq 'HALTED') {
        $ConnectButton.Content = 'Connected'
    }
    else {
        $ConnectButton.Content = 'Connect'
    }

    if (Test-Path -LiteralPath $script:session.EventsPath -PathType Leaf) {
        try {
            $allLines = @(Get-Content -LiteralPath $script:session.EventsPath)
            $lines = @($allLines | Select-Object -Last 200)

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
                if ($line -match 'BREAKPOINT_ADDED id=(\d+)\s+(.+)$') {
                    $breakpoints[$Matches[1]] = $Matches[2]
                }
                elseif ($line -match 'BREAKPOINT_REMOVED id=(\d+)') {
                    $breakpoints.Remove($Matches[1])
                }
            }
            $script:activeBreakpointIds = @($breakpoints.Keys)

            if ($script:pendingBreakpointSpec) {
                $newBreakpointLines = @($allLines | Select-Object -Skip $script:pendingBreakpointLineCount)
                $addedSpec = [regex]::Escape($script:pendingBreakpointSpec)
                if ($newBreakpointLines | Where-Object { $_ -match "BREAKPOINT_ADDED id=\d+\s+$addedSpec$" } | Select-Object -First 1) {
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
                $errorMessage = ($breakpointError -split "`t", 2)[1]
                [System.Windows.MessageBox]::Show($errorMessage, 'Breakpoint error') | Out-Null
            }

            $stopEvent = $lines | Where-Object { $_ -match '\t(BREAKPOINT_HIT|TARGET_SUSPENDED|TARGET_HALTED)\s' } | Select-Object -Last 1
            if ($stopEvent) {
                $stopMessage = ($stopEvent -split "`t", 2)[1]
                $StopText.Text = "Last stop: $stopMessage"
                if ($stopMessage -match '^BREAKPOINT_HIT' -and $stopEvent -ne $script:lastStopEvent) {
                    $script:lastStopEvent = $stopEvent
                    [System.Windows.MessageBox]::Show($stopMessage, 'Breakpoint hit') | Out-Null
                }
            }
            $items = @($breakpoints.GetEnumerator() | ForEach-Object { "ID $($_.Key)  $($_.Value)" })
            if ((@($BreakpointListBox.Items | ForEach-Object { [string]$_ }) -join "`n") -ne ($items -join "`n")) {
                $BreakpointListBox.Items.Clear()
                foreach ($item in $items) { [void]$BreakpointListBox.Items.Add($item) }
            }
        }
        catch {}
    }
}

$BuildButton.Add_Click({
    if (Test-Path -LiteralPath $buildStatusPath -PathType Leaf) {
        $currentBuildStatus = (Get-Content -Raw -LiteralPath $buildStatusPath).Trim()
        if ($currentBuildStatus.StartsWith('BUILDING')) {
            [System.Windows.MessageBox]::Show('A build is already running.', 'Build') | Out-Null
            return
        }
    }
    if (Test-Path -LiteralPath $downloadStatusPath -PathType Leaf) {
        $currentDownloadStatus = (Get-Content -Raw -LiteralPath $downloadStatusPath).Trim()
        if (($currentDownloadStatus -split ';', 2)[0] -in @('BUILDING', 'STOPPING_SESSION', 'DOWNLOADING')) {
            [System.Windows.MessageBox]::Show('A build/download operation is already running.', 'Build and download') | Out-Null
            return
        }
    }
    $answer = [System.Windows.MessageBox]::Show(
        "编译成功后将停止当前共享调试会话，连接 XDS2xx 并下载新程序到目标板。下载后 CPU 保持暂停，不会自动 Resume。`r`n`r`n请确认 CCS Debug 已断开且设备处于安全状态。",
        '编译并下载', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $BuildButton.IsEnabled = $false
    $BuildText.Text = 'Build: STARTING'
    $DownloadText.Text = 'Download: BUILDING'
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
            Get-Content -Raw -LiteralPath $script:session.StatusPath
        } else { '' }
        $sessionProcess = if ($script:session -and $script:session.ProcessId) {
            Get-Process -Id ([int]$script:session.ProcessId) -ErrorAction SilentlyContinue
        } else { $null }

        if ($sessionProcess -and $currentStatus -match '^DISCONNECTED') {
            Send-DebugCommand 'RECONNECT'
        }
        elseif ($sessionProcess -and $currentStatus -match '^(RUNNING|HALTED)') {
            [System.Windows.MessageBox]::Show('The shared debug session is already connected.', 'Shared Debug') | Out-Null
        }
        else {
            $answer = [System.Windows.MessageBox]::Show(
                'Connecting XDS2xx may halt the CPU. Confirm the machine is safe and the CCS Debug session is disconnected.',
                'Connect shared debug', 'YesNo', 'Warning')
            if ($answer -eq 'Yes') {
                & $launcherPath -AllowHardware -NoPanel
            }
        }
    }
    catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Connect failed') | Out-Null
    }
})
$ResumeButton.Add_Click({ Send-DebugCommand 'RESUME' })
$SuspendButton.Add_Click({ Send-DebugCommand 'SUSPEND' })
$SnapshotButton.Add_Click({ Send-DebugCommand 'SNAPSHOT' })
$WatchButton.Add_Click({
    $watch = (($WatchBox.Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ';'
    Send-DebugCommand "WATCH $watch"
    Send-DebugCommand 'SNAPSHOT'
})
$ReadButton.Add_Click({
    Commit-ExpressionGrid
    Update-Session
    $lineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
        @(Get-Content -LiteralPath $script:session.EventsPath).Count
    } else { 0 }
    $expressions = @($expressionTable.Rows | ForEach-Object { ([string]$_['Expression']).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($expressions.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Add at least one expression first.', 'Read expressions') | Out-Null
        return
    }
    foreach ($expression in $expressions) {
        $script:pendingReads[$expression] = $lineCount
        Send-DebugCommand "READ $expression"
    }
})
$SetButton.Add_Click({
    Commit-ExpressionGrid
    $selectedRow = $ExpressionGrid.SelectedItem
    if ($selectedRow -isnot [System.Data.DataRowView]) {
        [System.Windows.MessageBox]::Show('Select one expression row to write.', 'Write expression') | Out-Null
        return
    }
    $expression = ([string]$selectedRow['Expression']).Trim()
    $value = ([string]$selectedRow['Value']).Trim()
    if (-not $expression -or -not $value) {
        [System.Windows.MessageBox]::Show('The selected row requires both Expression and Value.', 'Write expression') | Out-Null
        return
    }
    if ($expression.Contains('=')) {
        [System.Windows.MessageBox]::Show('Expression must not contain an assignment operator.', 'Write expression') | Out-Null
        return
    }
    Update-Session
    $lineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
        @(Get-Content -LiteralPath $script:session.EventsPath).Count
    } else { 0 }
    $script:pendingWrites[$expression] = $lineCount
    Send-DebugCommand "SET $expression=$value"
})
$AddBreakpointButton.Add_Click({
    $specification = $BreakpointBox.Text.Trim()
    if ($specification) {
        Update-Session
        $script:pendingBreakpointSpec = $specification
        $script:pendingBreakpointLineCount = if ($script:session -and (Test-Path -LiteralPath $script:session.EventsPath)) {
            @(Get-Content -LiteralPath $script:session.EventsPath).Count
        } else { 0 }
        Send-DebugCommand "BREAKADD $specification"
    }
})
$RemoveBreakpointButton.Add_Click({
    $id = $BreakpointIdBox.Text.Trim()
    if ($id) { Send-DebugCommand "BREAKREMOVE $id" }
})
$BreakpointListBox.Add_SelectionChanged({
    if ($BreakpointListBox.SelectedItem -match '^ID\s+(\d+)') {
        $BreakpointIdBox.Text = $Matches[1]
    }
})
$StopButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('Clear all breakpoints and disconnect the shared DSS session from XDS2xx?', 'Shared Debug', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        foreach ($id in $script:activeBreakpointIds) { Send-DebugCommand "BREAKREMOVE $id" }
        Send-DebugCommand 'STOP'
    }
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ Refresh-Display })
$timer.Start()
Refresh-Display
$window.ShowDialog() | Out-Null
