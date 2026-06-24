# ============================================
# Intune Win32 Bulk Management v3.0
# Enhanced with Group Assignments & Dashboard
# ============================================

#region Startup Configuration

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# C# helper: schedules SelectAll on a TextBox via a native DispatcherTimer lambda so the
# selection fires after all WPF input events complete — no PowerShell session-context risk.
# Use actual loaded-assembly paths so the C# compiler can resolve them on every system.
$_wpfRefs = @(
    [System.Reflection.Assembly]::GetAssembly([System.Windows.DependencyObject]).Location,   # WindowsBase
    [System.Reflection.Assembly]::GetAssembly([System.Windows.FrameworkElement]).Location,   # PresentationFramework
    [System.Reflection.Assembly]::GetAssembly([System.Windows.Media.Brush]).Location         # PresentationCore
)
# Compile only when the type (or the specific HookHorizontalWheel method) is not yet present.
# If an older WpfTextHelper without HookHorizontalWheel is already loaded in this session,
# we cannot recompile — the user must start a fresh PowerShell session.
$_needsCompile = $true
$_wpfHelperType = ([System.Management.Automation.PSTypeName]'WpfTextHelper').Type
if ($null -ne $_wpfHelperType) {
    if ($null -ne $_wpfHelperType.GetMethod('HookHorizontalWheel')) {
        $_needsCompile = $false   # type is current — skip Add-Type
    } else {
        $_needsCompile = $false   # can't recompile; user must start a fresh PowerShell session
    }
}
if ($_needsCompile) {
Add-Type -TypeDefinition @"
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;

public static class WpfTextHelper {
    public static void SelectAllDeferred(TextBox tb, int delayMs) {
        if (tb == null) return;
        var timer = new DispatcherTimer();
        timer.Interval = TimeSpan.FromMilliseconds(delayMs);
        timer.Tick += (s, e) => {
            timer.Stop();
            tb.Focus();
            tb.SelectAll();
            if (!string.IsNullOrEmpty(tb.Text))
                Clipboard.SetText(tb.Text);
        };
        timer.Start();
    }

    private static ScrollViewer _hsv;

    public static void HookHorizontalWheel(HwndSource hwndSource, ScrollViewer sv) {
        _hsv = sv;
        hwndSource.AddHook(HwndHook);
    }

    private static IntPtr HwndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == 0x020E && _hsv != null && _hsv.ScrollableWidth > 0) {
            short delta = (short)(wParam.ToInt64() >> 16);
            if (delta > 0) _hsv.LineRight();
            else if (delta < 0) _hsv.LineLeft();
            handled = true;
        }
        return IntPtr.Zero;
    }
}
"@ -ReferencedAssemblies $_wpfRefs
} # end if $_needsCompile

#endregion

#region Paths & File Loading

$ScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent

$XamlFile = Join-Path $ScriptRoot "XAML\MainWindow.xaml"
$AssignmentXamlFile = Join-Path $ScriptRoot "XAML\AssignmentWindow.xaml"

# Import modules
Import-Module "$ScriptRoot\Modules\Logging.psm1" -Force
Import-Module "$ScriptRoot\Modules\Graph.psm1" -Force
Import-Module "$ScriptRoot\Modules\AppOperations.psm1" -Force

#endregion

#region Load XAML

[xml]$Xaml = Get-Content $XamlFile -Raw
$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

[xml]$AssignmentXaml = Get-Content $AssignmentXamlFile -Raw

#endregion

#region Control References

# Main Window Controls
$btnConnect = $Window.FindName("btnConnect")
$chkSelectAll = $Window.FindName("chkSelectAll")
$btnRefresh = $Window.FindName("btnRefresh")
$btnAssignGroups = $Window.FindName("btnAssignGroups")
$btnViewDetails = $Window.FindName("btnViewDetails")
$btnDelete = $Window.FindName("btnDelete")
$btnExport = $Window.FindName("btnExport")
$btnBackup = $Window.FindName("btnBackup")
$btnClearLog = $Window.FindName("btnClearLog")
$btnOpenPortal = $Window.FindName("btnOpenPortal")
$btnExportAssignments = $Window.FindName("btnExportAssignments")
$cmbStatusFilter = $Window.FindName("cmbStatusFilter")
$cmbPublisherFilter = $Window.FindName("cmbPublisherFilter")
$txtSearch = $Window.FindName("txtSearch")
$dgApps = $Window.FindName("dgApps")
$txtLog = $Window.FindName("txtLog")
$pbProgress = $Window.FindName("pbProgress")
$txtProgress = $Window.FindName("txtProgress")
$txtStatus = $Window.FindName("txtStatus")
$txtTenantName = $Window.FindName("txtTenantName")
$txtTenantId = $Window.FindName("txtTenantId")
$txtUser = $Window.FindName("txtUser")

# Dashboard Stats
$statTotalApps = $Window.FindName("statTotalApps")
$statSelectedApps = $Window.FindName("statSelectedApps")
$statSyncStatus = $Window.FindName("statSyncStatus")
$statLastSync = $Window.FindName("statLastSync")

#endregion

#region Control Validation

$RequiredControls = @{
    btnConnect       = $btnConnect
    chkSelectAll     = $chkSelectAll
    btnRefresh       = $btnRefresh
    btnAssignGroups  = $btnAssignGroups
    btnViewDetails   = $btnViewDetails
    btnDelete        = $btnDelete
    btnExport        = $btnExport
    btnBackup        = $btnBackup
    btnClearLog      = $btnClearLog
    txtSearch        = $txtSearch
    dgApps           = $dgApps
    txtLog           = $txtLog
    pbProgress       = $pbProgress
    txtProgress      = $txtProgress
    txtStatus        = $txtStatus
    txtTenantName    = $txtTenantName
    txtTenantId      = $txtTenantId
    txtUser          = $txtUser
    statTotalApps    = $statTotalApps
    statSelectedApps = $statSelectedApps
    statSyncStatus   = $statSyncStatus
    statLastSync     = $statLastSync
}

$MissingControls = $RequiredControls.GetEnumerator() | Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Key }

if ($MissingControls) {
    $MissingList = $MissingControls -join ", "
    try {
        Show-AppPopup -Title "XAML Error" -Message ("Missing XAML controls: {0}" -f $MissingList)
    } catch {
        # If Show-AppPopup isn't available yet during early startup, fallback
        [System.Windows.MessageBox]::Show(
            "Missing XAML controls: $MissingList",
            "XAML Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
    throw "Startup aborted: Missing controls -> $MissingList"
}

#endregion

#region Enhanced Logging

function Write-UILogWithTimestamp {
    param([string]$Message, [string]$Level = "INFO")

    $Timestamp = Get-Date -Format "HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"

    # Make UI feel responsive: flush log + process UI events
    $txtLog.AppendText($LogEntry + "`r`n")
    $txtLog.CaretIndex = $txtLog.Text.Length
    $txtLog.ScrollToEnd()

    [System.Windows.Forms.Application]::DoEvents() | Out-Null
}

#endregion

#region Dashboard Updates

function Update-Dashboard {
    param([object[]]$AllApps, [object[]]$SelectedApps)
    
    $totalCount = if ($AllApps) { $AllApps.Count } else { 0 }
    $selectedCount = if ($SelectedApps) { $SelectedApps.Count } else { 0 }
    
    $statTotalApps.Text = $totalCount.ToString()
    $statSelectedApps.Text = $selectedCount.ToString()
    $statLastSync.Text = Get-Date -Format "HH:mm:ss"
    
    if ($Script:IsConnected) {
        $statSyncStatus.Text = "In Sync"
    } else {
        $statSyncStatus.Text = "Not Connected"
    }
}

#endregion

#region Fix: Single-Click Checkbox Editing

# This fixes the double-click issue by setting the right edit trigger


# Helper to find parent control


#endregion

#region Global Variables

$Script:GridData = @()
$Script:IsConnected = $false
$Script:AssignmentWindow = $null
$Script:SelectedGroups = @()
$Script:SettingsPath = Join-Path $env:APPDATA "IntuneWin32BulkManagement\settings.json"

#endregion

#region Helper Functions

function Get-CurrentScreen {
    try {
        $ps = [System.Windows.PresentationSource]::FromVisual($Window)
        if ($null -eq $ps) { return $null }
        $pt = $Window.PointToScreen([System.Windows.Point]::new($Window.ActualWidth / 2, $Window.ActualHeight / 2))
        return [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new([int]$pt.X, [int]$pt.Y))
    } catch { return $null }
}

function Fit-WindowToScreen {
    param([System.Windows.Forms.Screen]$Screen = $null, [switch]$Center)
    try {
        if ($null -eq $Screen) { $Screen = Get-CurrentScreen }
        if ($null -eq $Screen) { return }

        $wa = $Screen.WorkingArea

        # Scale to 95 % of the working area, with sensible min/max bounds
        $newW = [Math]::Floor([Math]::Min([Math]::Max($wa.Width  * 0.95, 1000), $wa.Width))
        $newH = [Math]::Floor([Math]::Min([Math]::Max($wa.Height * 0.92,  640), $wa.Height))

        $Window.Width  = [double]$newW
        $Window.Height = [double]$newH

        if ($Center) {
            $Window.Left = [double]($wa.Left + [Math]::Floor(($wa.Width  - $newW) / 2))
            $Window.Top  = [double]($wa.Top  + [Math]::Floor(($wa.Height - $newH) / 2))
        } else {
            # Clamp: keep window fully on-screen without forcing a re-center
            $Window.Left = [double][Math]::Max($wa.Left, [Math]::Min($Window.Left, $wa.Right  - $Window.Width))
            $Window.Top  = [double][Math]::Max($wa.Top,  [Math]::Min($Window.Top,  $wa.Bottom - $Window.Height))
        }

        # no-op: log row is now fixed height
    }
    catch { }
}

# Keep the old name as a thin alias so existing call-sites still work
function Center-WindowToCurrentMonitor { Fit-WindowToScreen -Center }

function Save-AppSettings {
    try {
        $dir = Split-Path $Script:SettingsPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $statusSel = "All Statuses"
        $pubSel = "All Publishers"
        try { if ($cmbStatusFilter -and $cmbStatusFilter.SelectedItem) { $statusSel = $cmbStatusFilter.SelectedItem.Content } } catch { }
        try { if ($cmbPublisherFilter -and $cmbPublisherFilter.SelectedItem) { $pubSel = $cmbPublisherFilter.SelectedItem.Content } } catch { }
        $settings = @{
            WindowWidth  = [int]$Window.Width
            WindowHeight = [int]$Window.Height
            WindowLeft   = [int]$Window.Left
            WindowTop    = [int]$Window.Top
            StatusFilter = $statusSel
            PublisherFilter = $pubSel
        }
        $settings | ConvertTo-Json | Set-Content -Path $Script:SettingsPath -Encoding UTF8
    }
    catch { }
}

function Load-AppSettings {
    try {
        if (-not (Test-Path $Script:SettingsPath)) { return }
        $s = Get-Content $Script:SettingsPath -Raw | ConvertFrom-Json
        if ($s.WindowWidth  -gt 800)  { $Window.Width  = [double]$s.WindowWidth }
        if ($s.WindowHeight -gt 400)  { $Window.Height = [double]$s.WindowHeight }
        if ($null -ne $s.WindowLeft -and $s.WindowLeft -ge 0)  { $Window.Left = [double]$s.WindowLeft }
        if ($null -ne $s.WindowTop  -and $s.WindowTop  -ge 0)  { $Window.Top  = [double]$s.WindowTop }
        if ($s.StatusFilter -and $cmbStatusFilter) {
            foreach ($item in $cmbStatusFilter.Items) {
                if ($item.Content -eq $s.StatusFilter) { $cmbStatusFilter.SelectedItem = $item; break }
            }
        }
    }
    catch { }
}

function Apply-GridFilter {
    try {
        $searchText = ""
        try { $searchText = $txtSearch.Text } catch { }

        $statusSel = "All Statuses"
        $pubSel    = "All Publishers"
        try { if ($cmbStatusFilter    -and $cmbStatusFilter.SelectedItem)    { $statusSel = $cmbStatusFilter.SelectedItem.Content } }    catch { }
        try { if ($cmbPublisherFilter -and $cmbPublisherFilter.SelectedItem) { $pubSel    = $cmbPublisherFilter.SelectedItem.Content } } catch { }

        $results = $Script:GridData | Where-Object {
            $matchSearch = [string]::IsNullOrWhiteSpace($searchText) -or
                           $_.DisplayName -like "*$searchText*" -or
                           $_.Description -like "*$searchText*" -or
                           $_.Publisher   -like "*$searchText*"
            $matchStatus = ($statusSel -eq "All Statuses") -or ($_.Status -eq $statusSel)
            $matchPub    = ($pubSel -eq "All Publishers")  -or ($_.Publisher -eq $pubSel)
            $matchSearch -and $matchStatus -and $matchPub
        }

        $dgApps.ItemsSource = $null
        $dgApps.ItemsSource = @($results)
        Update-Dashboard -AllApps @($results)
    }
    catch {
        Write-UILogWithTimestamp -Message "Filter error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Update-PublisherFilter {
    try {
        if (-not $cmbPublisherFilter) { return }
        $current = "All Publishers"
        try { if ($cmbPublisherFilter.SelectedItem) { $current = $cmbPublisherFilter.SelectedItem.Content } } catch { }

        $publishers = @($Script:GridData |
            Select-Object -ExpandProperty Publisher -Unique |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object)

        $cmbPublisherFilter.Items.Clear()
        $allItem = New-Object System.Windows.Controls.ComboBoxItem
        $allItem.Content = "All Publishers"
        $cmbPublisherFilter.Items.Add($allItem) | Out-Null

        foreach ($pub in $publishers) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $pub
            $cmbPublisherFilter.Items.Add($item) | Out-Null
        }

        # Restore previous selection if still valid
        $restored = $false
        foreach ($item in $cmbPublisherFilter.Items) {
            if ($item.Content -eq $current) { $cmbPublisherFilter.SelectedItem = $item; $restored = $true; break }
        }
        if (-not $restored) { $cmbPublisherFilter.SelectedIndex = 0 }
    }
    catch { }
}

function Show-AppPopup {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Message
    )

    try {
        $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dialog"
        WindowStartupLocation="CenterOwner"
        SizeToContent="Height"
        Width="560"
        MinHeight="200"
        MaxHeight="620"
        ResizeMode="NoResize"
        Background="#F3F6FB" FontFamily="Segoe UI">
    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Name="txtPopupTitle" Grid.Row="0" FontWeight="Bold" FontSize="15"
                   Foreground="#1B2430" Margin="0,0,0,14"/>

        <Border Grid.Row="1" CornerRadius="10" Background="#FFFFFF" BorderBrush="#E7EBF1" BorderThickness="1" Padding="16">
            <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="400">
                <TextBox Name="txtPopupMessage" IsReadOnly="True" TextWrapping="Wrap"
                         Background="Transparent" BorderThickness="0" FontSize="12.5"
                         Foreground="#374151" AcceptsReturn="True" IsTabStop="False"
                         FontFamily="Segoe UI"/>
            </ScrollViewer>
        </Border>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button Name="btnOk" Content="OK" Width="90" Height="36" Cursor="Hand" IsDefault="True"
                    FontSize="13" FontWeight="SemiBold" Foreground="White" FocusVisualStyle="{x:Null}">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="#1F6FEB" CornerRadius="18" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="20,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#3A82F2"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#0F4C81"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@

        $reader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
        $w = [Windows.Markup.XamlReader]::Load($reader)
        $w.Owner = $Window
        $w.Title = $Title

        # Set text programmatically to avoid XML escaping issues with special characters
        $w.FindName("txtPopupTitle").Text = $Title
        $w.FindName("txtPopupMessage").Text = $Message

        $btnOk = $w.FindName("btnOk")
        $btnOk.Add_Click({ $w.DialogResult = $true; $w.Close() })
        $w.ShowDialog() | Out-Null
    }
    catch {
        return
    }
}

function Show-ConfirmPopup {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$ConfirmLabel = "Yes",
        [string]$CancelLabel  = "Cancel",
        [string]$ConfirmColor = "#D64545",
        [string]$ConfirmHover = "#B83A3A"
    )

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm"
        WindowStartupLocation="CenterOwner"
        SizeToContent="Height"
        Width="480"
        MinHeight="160"
        MaxHeight="400"
        ResizeMode="NoResize"
        Background="#F3F6FB" FontFamily="Segoe UI">
    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Name="txtTitle" Grid.Row="0" FontWeight="Bold" FontSize="15"
                   Foreground="#1B2430" Margin="0,0,0,14"/>

        <Border Grid.Row="1" CornerRadius="10" Background="#FFFFFF"
                BorderBrush="#E7EBF1" BorderThickness="1" Padding="16,12">
            <TextBlock Name="txtMessage" FontSize="12.5" TextWrapping="Wrap"
                       Foreground="#374151" LineHeight="20"/>
        </Border>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button Name="btnNo" Width="100" Height="36" Cursor="Hand"
                    FontSize="13" FontWeight="SemiBold" FocusVisualStyle="{x:Null}" Margin="0,0,10,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="White" BorderBrush="#D9DEE6" BorderThickness="1"
                                CornerRadius="18" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="20,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#EEF2F8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button Name="btnYes" Width="100" Height="36" Cursor="Hand" IsDefault="True"
                    FontSize="13" FontWeight="SemiBold" Foreground="White" FocusVisualStyle="{x:Null}">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="$ConfirmColor" CornerRadius="18" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="20,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="$ConfirmHover"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#8B2020"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
        $w = [Windows.Markup.XamlReader]::Load($reader)
        $w.Owner = $Window

        $w.FindName("txtTitle").Text   = $Title
        $w.FindName("txtMessage").Text = $Message
        $w.FindName("btnYes").Content  = $ConfirmLabel
        $w.FindName("btnNo").Content   = $CancelLabel

        $w.FindName("btnYes").Add_Click({ $w.DialogResult = $true;  $w.Close() })
        $w.FindName("btnNo").Add_Click({  $w.DialogResult = $false; $w.Close() })

        $dlgResult = $w.ShowDialog()
        return ($dlgResult -eq $true)
    }
    catch {
        $fb = [System.Windows.MessageBox]::Show($Message, $Title,
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        return ($fb -eq [System.Windows.MessageBoxResult]::Yes)
    }
}

function Show-AppDetailsPopup {
    param([Parameter(Mandatory=$true)][object]$App)

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="App Details"
        WindowStartupLocation="CenterOwner"
        SizeToContent="Height"
        Width="620"
        MinHeight="300"
        MaxHeight="700"
        ResizeMode="NoResize"
        Background="#F3F6FB" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="IsInactiveSelectionHighlightEnabled" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <ScrollViewer x:Name="PART_ContentHost" Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="8"/>
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid x:Name="Root" Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Width="0" Height="0" Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border x:Name="bg" Background="#C4CBD6" CornerRadius="4" Margin="2,3"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="bg" Property="Background" Value="#9BA8B7"/>
                                                    </Trigger>
                                                    <Trigger Property="IsDragging" Value="True">
                                                        <Setter TargetName="bg" Property="Background" Value="#1F6FEB"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Width="0" Height="0" Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Vertical">
                                <Setter TargetName="Root" Property="Width" Value="8"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="True"/>
                                <Setter TargetName="PART_Track" Property="Orientation" Value="Vertical"/>
                            </Trigger>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter TargetName="Root" Property="Height" Value="16"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                                <Setter TargetName="PART_Track" Property="Orientation" Value="Horizontal"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="MinWidth" Value="0"/>
                    <Setter Property="Height" Value="16"/>
                    <Setter Property="MinHeight" Value="16"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="App Details" FontWeight="Bold" FontSize="16"
                   Foreground="#1B2430" Margin="0,0,0,16"/>

        <!-- Two-column table card -->
        <Border Grid.Row="1" CornerRadius="10" Background="#FFFFFF"
                BorderBrush="#E7EBF1" BorderThickness="1" ClipToBounds="True">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Display Name" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valDisplayName" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" FontWeight="SemiBold" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="1" Background="#F8FAFD" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Version" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valVersion" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Publisher" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valPublisher" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="3" Background="#F8FAFD" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Description" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valDescription" FontSize="12" Foreground="#6B7787" TextWrapping="Wrap" VerticalAlignment="Top" MaxHeight="90" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="4" Background="#FFFFFF" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Status" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valStatus" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" FontWeight="SemiBold" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="5" Background="#F8FAFD" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Assigned Groups" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valAssignedGroups" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="6" Background="#FFFFFF" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Intent" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valIntent" FontSize="12" Foreground="#1B2430" TextWrapping="Wrap" VerticalAlignment="Top" FontWeight="SemiBold" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
                <Border Grid.Row="7" Background="#FFFFFF" Padding="16,11">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="App ID" FontWeight="SemiBold" FontSize="12" Foreground="#5B6677" VerticalAlignment="Top"/>
                        <TextBox Grid.Column="1" Name="valAppId" FontSize="11" Foreground="#6B7787" TextWrapping="Wrap" VerticalAlignment="Top" FontFamily="Consolas" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0" FocusVisualStyle="{x:Null}"/>
                    </Grid>
                </Border>
            </Grid>
        </Border>

        <TextBlock Grid.Row="2" Text="Double-click any field to copy its value to clipboard."
                   FontSize="10.5" Foreground="#9BA8B7" Margin="0,10,0,0" HorizontalAlignment="Left"/>

        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button Name="btnDeviceStatus" Content="Device Status" Width="130" Height="36" Cursor="Hand"
                    FontSize="13" FontWeight="SemiBold" Foreground="#1B2430" FocusVisualStyle="{x:Null}" Margin="0,0,10,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="White" BorderBrush="#D9DEE6" BorderThickness="1" CornerRadius="18" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#EEF2F8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button Name="btnOk" Content="OK" Width="90" Height="36" Cursor="Hand" IsDefault="True"
                    FontSize="13" FontWeight="SemiBold" Foreground="White" FocusVisualStyle="{x:Null}">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="#1F6FEB" CornerRadius="18" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="20,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#3A82F2"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#0F4C81"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)
        $w = [Windows.Markup.XamlReader]::Load($reader)
        $w.Owner = $Window

        $w.FindName("valDisplayName").Text    = [string]$App.DisplayName
        $w.FindName("valVersion").Text        = [string]$App.Version
        $w.FindName("valPublisher").Text      = [string]$App.Publisher
        $w.FindName("valDescription").Text    = [string]$App.Description
        $w.FindName("valStatus").Text         = [string]$App.Status
        $w.FindName("valAssignedGroups").Text = if ([string]::IsNullOrWhiteSpace($App.AssignedGroups))    { "None" } else { [string]$App.AssignedGroups }
        $w.FindName("valIntent").Text         = if ([string]::IsNullOrWhiteSpace($App.AssignmentIntent))  { "-" }    else { [string]$App.AssignmentIntent }
        $w.FindName("valAppId").Text          = [string]$App.Id

        # Double-click any field → select all text + copy to clipboard.
        # WpfTextHelper.SelectAllDeferred uses a native C# DispatcherTimer lambda so the
        # 100 ms deferred SelectAll runs without PowerShell session-context issues.
        $w.Add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            if ($e.ClickCount -ne 2) { return }
            $el = $e.OriginalSource
            while ($null -ne $el) {
                if ($el -is [System.Windows.Controls.TextBox]) {
                    [WpfTextHelper]::SelectAllDeferred($el, 100)
                    break
                }
                try { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) } catch { break }
            }
        })

        # SelectionChanged auto-copies manual drag-selection so text stays in the clipboard
        # even if the visual highlight disappears when focus moves elsewhere.
        foreach ($fieldName in @("valDisplayName","valVersion","valPublisher","valDescription","valStatus","valAssignedGroups","valIntent","valAppId")) {
            $tb = $w.FindName($fieldName)
            if ($tb) {
                $tb.Add_SelectionChanged({
                    param($sender, $e)
                    if ($sender.SelectionLength -gt 0) {
                        [System.Windows.Clipboard]::SetText($sender.SelectedText)
                    }
                })
            }
        }

        $Script:DetailsAppId   = ([string]$App.Id).Trim()
        $Script:DetailsAppName = ([string]$App.DisplayName).Trim()
        $w.FindName("btnDeviceStatus").Add_Click({
            try {
                $appId   = $Script:DetailsAppId
                $appName = $Script:DetailsAppName

                if ([string]::IsNullOrWhiteSpace($appId)) {
                    Show-AppPopup -Title "Device Status" -Message "App ID is empty — cannot retrieve status."
                    return
                }

                # Try installSummary (device counts) first
                $summaryLoaded = $false
                try {
                    $summaryUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/installSummary"
                    $result = Invoke-MgGraphRequest -Method GET -Uri $summaryUri
                    $installed     = [int]($result["installedDeviceCount"])
                    $failed        = [int]($result["failedDeviceCount"])
                    $pending       = [int]($result["pendingInstallDeviceCount"])
                    $notInstalled  = [int]($result["notInstalledDeviceCount"])
                    $notApplicable = [int]($result["notApplicableDeviceCount"])
                    $summary = "Deployment Status — $appName`n`n" +
                               "Installed     : $installed`n" +
                               "Failed        : $failed`n" +
                               "Pending       : $pending`n" +
                               "Not Installed : $notInstalled`n" +
                               "Not Applicable: $notApplicable"
                    Show-AppPopup -Title "Device Status" -Message $summary
                    $summaryLoaded = $true
                }
                catch { }

                if (-not $summaryLoaded) {
                    # Fallback: show assignment-level breakdown (always available)
                    $assignUri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId/assignments"
                    $assignResult = Invoke-MgGraphRequest -Method GET -Uri $assignUri
                    $assignments = @($assignResult["value"])
                    if ($assignments.Count -eq 0) {
                        Show-AppPopup -Title "Device Status" -Message "No assignments found for '$appName'.`nDeploy the app to a group first."
                        return
                    }
                    $required  = @($assignments | Where-Object { $_["intent"] -eq "required" }).Count
                    $available = @($assignments | Where-Object { $_["intent"] -eq "available" }).Count
                    $uninstall = @($assignments | Where-Object { $_["intent"] -eq "uninstall" }).Count
                    $summary = "Assignment Summary — $appName`n`n" +
                               "Required  : $required group(s)`n" +
                               "Available : $available group(s)`n" +
                               "Uninstall : $uninstall group(s)`n" +
                               "Total     : $($assignments.Count) assignment(s)`n`n" +
                               "(Real-time device counts require Intune reporting permissions)"
                    Show-AppPopup -Title "Device Status" -Message $summary
                }
            }
            catch {
                Show-AppPopup -Title "Device Status Error" -Message $_.Exception.Message
            }
        })

        $w.FindName("btnOk").Add_Click({ $w.DialogResult = $true; $w.Close() })
        $w.ShowDialog() | Out-Null
    }
    catch {
        Show-AppPopup -Title "App Details" -Message "$($App.DisplayName) | $($App.Version) | $($App.Status)"
    }
}

function Update-SelectedCount {
    try {
        # Re-count directly from the current grid item objects.
        if (-not $dgApps) { return }
        $items = @($dgApps.ItemsSource)
        $selected = $items | Where-Object { $_.Selected -eq $true }
        Update-Dashboard -AllApps $items -SelectedApps $selected
    }
    catch {
        Write-UILogWithTimestamp -Message "Update-SelectedCount error: $($_.Exception.Message)" -Level "ERROR"
    }
}


function Update-SelectAllCheckbox {
    try {
        if (-not $dgApps) { return }
        $items = @($dgApps.ItemsSource)
        $allCount = if ($items) { $items.Count } else { 0 }
        $selectedCount = ($items | Where-Object { $_.Selected -eq $true } | Measure-Object).Count

        if ($selectedCount -eq 0) {
            $chkSelectAll.IsChecked = $false
        } elseif ($selectedCount -eq $allCount -and $allCount -gt 0) {
            $chkSelectAll.IsChecked = $true
        } else {
            $chkSelectAll.IsChecked = $null  # Indeterminate
        }
    }
    catch {
        Write-UILogWithTimestamp -Message "Update-SelectAllCheckbox error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Load-Apps {
    $pbProgress.Value = 0
    $txtStatus.Text = "Loading applications..."

    # reset warning markers

    if ($txtProgress) {
        $txtProgress.Text = "0%"
    }

    try {
        Write-UILogWithTimestamp -Message "Loading applications..." -Level "INFO"
        $pbProgress.Value = 10
        [System.Windows.Forms.Application]::DoEvents() | Out-Null

        $Script:GridData = @(Get-AppGridData)
        $pbProgress.Value = 70
        [System.Windows.Forms.Application]::DoEvents() | Out-Null

        # Always bind UI even if dashboard update fails.
        try {
            $dgApps.ItemsSource = $null
            $dgApps.ItemsSource = $Script:GridData
            $Window.Title = "Intune Win32 Bulk Management ($($Script:GridData.Count) Apps)"
        }
        catch {
            throw
        }

        $pbProgress.Value = 100
        $txtProgress.Text = "100%"
        [System.Windows.Forms.Application]::DoEvents() | Out-Null

        try {
            Update-PublisherFilter
            Apply-GridFilter
        }
        catch {
            Write-UILogWithTimestamp -Message "Filter populate failed: $($_.Exception.Message)" -Level "WARN"
        }

        try {
            Update-Dashboard -AllApps $Script:GridData
        }
        catch {
            # Dashboard issues shouldn't prevent app list from showing.
            Write-UILogWithTimestamp -Message "Dashboard update failed: $($_.Exception.Message)" -Level "ERROR"
        }

        Write-UILogWithTimestamp -Message "$($Script:GridData.Count) apps loaded successfully" -Level "SUCCESS"
        $txtStatus.Text = "Ready - $($Script:GridData.Count) apps loaded"
    }
    catch {
        $msg = $_.Exception.Message

        # Always attempt to append ErrorDetails.
        $detailsSafe = ''
        try { $detailsSafe = $_.ErrorDetails.Message } catch { $detailsSafe = '' }

        $invInfo = ''
        try { $invInfo = ($_.InvocationInfo | Out-String) } catch { $invInfo = '' }

        $stack = ''
        try { $stack = ($_.ScriptStackTrace) } catch { $stack = '' }

        $full = $msg + " | Details: " + $detailsSafe
        if ($invInfo) { $full += "`r`nInvocationInfo:`r`n" + $invInfo }
        if ($stack)   { $full += "`r`nScriptStackTrace:`r`n" + $stack }

        Write-UILogWithTimestamp -Message "Error loading apps: $full" -Level "ERROR"

        # Force-bind UI if we have GridData; never leave the grid blank due to logging/dashboard exceptions.
        try {
            if ($null -ne $Script:GridData -and $Script:GridData.Count -gt 0) {
                $dgApps.ItemsSource = $null
                $dgApps.ItemsSource = $Script:GridData
                $txtStatus.Text = "Ready - $($Script:GridData.Count) apps loaded (warnings)"
            }
            else {
                # Only set error if we truly don't have items to show.
                $itemsNow = @($dgApps.ItemsSource)
                if ($itemsNow -and $itemsNow.Count -gt 0) {
                    $txtStatus.Text = "Ready - $($itemsNow.Count) apps loaded (warnings)"
                }
                else {
                    $txtStatus.Text = "Error loading apps"
                }
            }
        }
        catch {
            # Last resort: don't force error if grid already has data.
            try {
                $itemsNow = @($dgApps.ItemsSource)
                if ($itemsNow -and $itemsNow.Count -gt 0) {
                    $txtStatus.Text = "Ready - $($itemsNow.Count) apps loaded (warnings)"
                    return
                }
            } catch { }
            $txtStatus.Text = "Error loading apps"
        }
    }
}

#endregion

#region Group Assignment Window

function Show-AssignmentWindow {
    param([object[]]$SelectedApps)
    
    if ($SelectedApps.Count -eq 0) {
        Write-UILogWithTimestamp -Message "No apps selected for group assignment" -Level "WARN"
        return
    }
    
    try {
            $Reader = New-Object System.Xml.XmlNodeReader $AssignmentXaml
        $AssignWindow = [Windows.Markup.XamlReader]::Load($Reader)

        # Wire up Assignment Window controls
        $txtSelectedAppsInfo      = $AssignWindow.FindName("txtSelectedAppsInfo")
        $lstAvailableGroups       = $AssignWindow.FindName("lstAvailableGroups")
        $txtSelectedGroupCount    = $AssignWindow.FindName("txtSelectedGroupCount")
        $txtSelectedGroupsList    = $AssignWindow.FindName("txtSelectedGroupsList")
        $btnLoadGroups            = $AssignWindow.FindName("btnLoadGroups")
        $btnSelectAll             = $AssignWindow.FindName("btnSelectAll")
        $btnDeselectAll           = $AssignWindow.FindName("btnDeselectAll")
        $btnAssignGroupsConfirm   = $AssignWindow.FindName("btnAssignGroups")
        $btnRemoveAssignments     = $AssignWindow.FindName("btnRemoveAssignments")
        $btnCancel                = $AssignWindow.FindName("btnCancel")
        $txtGroupSearch           = $AssignWindow.FindName("txtGroupSearch")
        $txtAssignmentStatus      = $AssignWindow.FindName("txtAssignmentStatus")
        $rdoRequired              = $AssignWindow.FindName("rdoRequired")
        $rdoAvailable             = $AssignWindow.FindName("rdoAvailable")
        $rdoUninstall             = $AssignWindow.FindName("rdoUninstall")
        $txtCurrentAssignments    = $AssignWindow.FindName("txtCurrentAssignments")
        $cmbScopeTag              = $AssignWindow.FindName("cmbScopeTag")
        $btnCopyFrom              = $AssignWindow.FindName("btnCopyFrom")

        # Populate current assignments panel
        try {
            $currentLines = @()
            foreach ($a in ($SelectedApps | Select-Object -First 4)) {
                if (-not [string]::IsNullOrWhiteSpace($a.AssignedGroups)) {
                    $currentLines += "$($a.DisplayName): $($a.AssignedGroups) [$($a.AssignmentIntent)]"
                } else {
                    $currentLines += "$($a.DisplayName): Not assigned"
                }
            }
            if ($SelectedApps.Count -gt 4) { $currentLines += "... and $($SelectedApps.Count - 4) more" }
            $txtCurrentAssignments.Text = $currentLines -join "`n"
        } catch { }

        # Load scope tags
        try {
            $scopeTagUri = "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags"
            $scopeTagResult = Invoke-MgGraphRequest -Method GET -Uri $scopeTagUri
            $scopeTags = @($scopeTagResult["value"])
            $noneTag = New-Object System.Windows.Controls.ComboBoxItem
            $noneTag.Content = "None (Default)"
            $noneTag.Tag = $null
            $cmbScopeTag.Items.Add($noneTag) | Out-Null
            foreach ($t in $scopeTags | Sort-Object { $_["displayName"] }) {
                $tagItem = New-Object System.Windows.Controls.ComboBoxItem
                $tagItem.Content = [string]$t["displayName"]
                $tagItem.Tag = [string]$t["id"]
                $cmbScopeTag.Items.Add($tagItem) | Out-Null
            }
            $cmbScopeTag.SelectedIndex = 0
        }
        catch {
            $noneTag = New-Object System.Windows.Controls.ComboBoxItem
            $noneTag.Content = "None (Default)"
            $noneTag.Tag = $null
            $cmbScopeTag.Items.Add($noneTag) | Out-Null
            $cmbScopeTag.SelectedIndex = 0
        }

        # Set app info
        $appNames = ($SelectedApps | Select-Object -ExpandProperty DisplayName | Select-Object -First 3) -join ", "
        if ($SelectedApps.Count -gt 3) {
            $appNames += "... (+$($SelectedApps.Count - 3) more)"
        }
        $txtSelectedAppsInfo.Text = "Assigning groups to $($SelectedApps.Count) app(s): $appNames"
        
        # Load groups data (used by both auto-load on window open and the Load More button)
        $loadGroupsScript = {
            try {
                $txtAssignmentStatus.Text = "Loading groups..."
                
                # Cache the full group list for search/filtering (prevents duplicates).
                # Use Script scope so the filter closure can access the same cache.
                $Script:AllGroupsCache = @()
                $lstAvailableGroups.Items.Clear()
                $txtSelectedGroupsList.Text = "-"  # keep UI consistent

                Write-UILogWithTimestamp -Message "AssignmentWindow: starting Entra group load (Graph)... " -Level "INFO"
                [System.Windows.Forms.Application]::DoEvents() | Out-Null

                $allGroups = @()

                $baseUri = "https://graph.microsoft.com/v1.0/groups?$select=id,displayName,mailNickname,visibility,createdDateTime&$top=50"
                $pageGroups = Get-AllGraphPages -Uri $baseUri

                foreach ($g in $pageGroups) {
                    $allGroups += [PSCustomObject]@{
                        GroupName          = $g.displayName
                        GroupId            = $g.id
                        MemberCount        = 0
                        IsSelected         = $false
                        MembershipStatus   = "New"
                        StatusColor        = "#10B981"
                    }
                }

                # Cache full list for filtering/search
                $Script:AllGroupsCache = $allGroups

                # Populate list once
                $lstAvailableGroups.ItemsSource = $null
                $lstAvailableGroups.ItemsSource = $Script:AllGroupsCache

                $txtAssignmentStatus.Text = "Loaded $($allGroups.Count) groups"
                Write-UILogWithTimestamp -Message "Loaded $($allGroups.Count) Entra groups for assignment" -Level "SUCCESS"
                [System.Windows.Forms.Application]::DoEvents() | Out-Null
            }
            catch {
                $err = $_.Exception.Message
                $details = ""
                try { if ($_.ErrorDetails) { $details = $_.ErrorDetails.Message } } catch { }

                $full = $err
                if (-not [string]::IsNullOrWhiteSpace($details)) {
                    $full = "$err`r`n$details"
                }

                $txtAssignmentStatus.Text = "Error loading groups"
                Write-UILogWithTimestamp -Message "AssignmentWindow: group load failed: $full" -Level "ERROR"

                # Make the failure visible in the dialog (not just in main log)
                try {
                    Show-AppPopup -Title "Group Load Error" -Message ("Failed to load Entra groups.`r`n`r`n{0}" -f $full)
                }
                catch {
                    # ignore secondary UI errors
                }
            }
        }

        # btnLoadGroups is now "Search Groups": filter using the cached full group list.
        # This prevents duplicate population and ensures Enter key search works identically.
        $allGroupsCache = @()

        # helper: apply filter (case-insensitive, no duplicates)
        $applyGroupSearch = {
            try {
                $query = ""
                try { $query = $txtGroupSearch.Text } catch { $query = "" }
                $query = [string]$query

                $cache = @($Script:AllGroupsCache)

                if (-not $cache -or $cache.Count -eq 0) {
                    $txtAssignmentStatus.Text = "No groups loaded yet"
                    return
                }

                if ([string]::IsNullOrWhiteSpace($query)) {
                    $lstAvailableGroups.ItemsSource = $cache
                    $txtAssignmentStatus.Text = "Showing all groups"
                    return
                }

                $q = $query.ToLowerInvariant()

                $filtered = $cache | Where-Object {
                    ($_.GroupName -and $_.GroupName.ToLowerInvariant() -like "*$q*") -or
                    ($_.GroupId   -and $_.GroupId.ToLowerInvariant()   -like "*$q*")
                }

                $lstAvailableGroups.ItemsSource = $filtered
                $txtAssignmentStatus.Text = "Found $($filtered.Count) group(s)"
            }
            catch {
                $txtAssignmentStatus.Text = "Search failed"
                Write-UILogWithTimestamp -Message "AssignmentWindow search failed: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        $btnLoadGroups.Add_Click({
            & $applyGroupSearch
        })

        # Enter key should run the same search as the Search Groups button
        $txtGroupSearch.Add_KeyDown({
            try {
                if ($_.Key -eq "Enter") {
                    # prevent default beep
                    $_.Handled = $true
                    & $applyGroupSearch
                }
            }
            catch { }
        })

        # Live filter: re-apply on every keystroke (filters in-memory cache, no API call)
        $txtGroupSearch.Add_TextChanged({
            try { & $applyGroupSearch } catch { }
        })

        # Auto-load groups when dialog opens
        # Keep the original loading script for initial population.
        Write-UILogWithTimestamp -Message "AssignmentWindow: opening -> auto-loading groups" -Level "INFO"
        [System.Windows.Forms.Application]::DoEvents() | Out-Null
        & $loadGroupsScript

        
        # Select/Deselect All buttons
        $btnSelectAll.Add_Click({
            foreach ($item in $lstAvailableGroups.Items) {
                $item.IsSelected = $true
            }
            $lstAvailableGroups.Items.Refresh()
        })
        
        $btnDeselectAll.Add_Click({
            foreach ($item in $lstAvailableGroups.Items) {
                $item.IsSelected = $false
            }
            $lstAvailableGroups.Items.Refresh()
        })
        
        # Confirm assignment — calls Graph API /assign to persist to Intune
        $btnAssignGroupsConfirm.Add_Click({
            $selectedGroups = @($lstAvailableGroups.Items | Where-Object { $_.IsSelected -eq $true })

            if ($selectedGroups.Count -eq 0) {
                Show-AppPopup -Title "No Groups Selected" -Message "Please select at least one group to assign."
                return
            }

            # Determine intent from radio buttons
            $intent = "required"
            if ($rdoAvailable -and $rdoAvailable.IsChecked) { $intent = "available" }
            elseif ($rdoUninstall -and $rdoUninstall.IsChecked) { $intent = "uninstall" }

            Write-UILogWithTimestamp -Message "Assigning $($selectedGroups.Count) group(s) to $($SelectedApps.Count) app(s) [intent: $intent]..." -Level "INFO"
            $txtAssignmentStatus.Text = "Assigning..."
            $btnAssignGroupsConfirm.IsEnabled = $false

            $errors = @()
            $succeeded = 0

            foreach ($app in $SelectedApps) {
                try {
                    # Build assignment objects for each selected group
                    $assignments = @()
                    foreach ($grp in $selectedGroups) {
                        $assignments += @{
                            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
                            "intent"      = $intent
                            "target"      = @{
                                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                                "groupId"     = $grp.GroupId
                            }
                            "settings"    = @{
                                "@odata.type"                  = "#microsoft.graph.win32LobAppAssignmentSettings"
                                "notifications"                = "showAll"
                                "deliveryOptimizationPriority" = "notConfigured"
                            }
                        }
                    }

                    $body = @{ "mobileAppAssignments" = $assignments }
                    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.Id)/assign"
                    Invoke-GraphPost -Uri $uri -Body $body

                    # Apply scope tag if one was selected
                    try {
                        if ($cmbScopeTag -and $cmbScopeTag.SelectedItem -and $cmbScopeTag.SelectedItem.Tag) {
                            $tagId = $cmbScopeTag.SelectedItem.Tag
                            $patchUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.Id)"
                            Invoke-MgGraphRequest -Method PATCH -Uri $patchUri `
                                -Body (@{ "roleScopeTagIds" = @($tagId) } | ConvertTo-Json -Depth 5) `
                                -ContentType "application/json"
                            Write-UILogWithTimestamp -Message "Applied scope tag to: $($app.DisplayName)" -Level "INFO"
                        }
                    }
                    catch {
                        Write-UILogWithTimestamp -Message "Scope tag apply failed for $($app.DisplayName): $($_.Exception.Message)" -Level "WARN"
                    }

                    # Update local grid object so the UI reflects the change immediately
                    $groupNames = ($selectedGroups | ForEach-Object { $_.GroupName }) -join "; "
                    $intentDisplay = switch ($intent) {
                        "required"                   { "Required" }
                        "available"                  { "Available" }
                        "uninstall"                  { "Uninstall" }
                        "availableWithoutEnrollment" { "Available (No Enroll)" }
                        default                      { $intent }
                    }
                    $app.AssignedGroups   = $groupNames
                    $app.AssignmentIntent = $intentDisplay
                    $app.Status           = "Assigned"
                    $app.AssignmentCount  = $selectedGroups.Count
                    $succeeded++

                    Write-UILogWithTimestamp -Message "Assigned [$intent]: $($app.DisplayName)" -Level "SUCCESS"
                }
                catch {
                    $errMsg = $_.Exception.Message
                    $errors += "$($app.DisplayName): $errMsg"
                    Write-UILogWithTimestamp -Message "Assignment failed for $($app.DisplayName): $errMsg" -Level "ERROR"
                }
            }

            $dgApps.Items.Refresh()
            $txtStatus.Text = "Ready"
            $AssignWindow.Close()

            if ($errors.Count -gt 0) {
                $errText = "Assigned $succeeded of $($SelectedApps.Count) app(s).`n`nErrors:`n" + ($errors -join "`n")
                Show-AppPopup -Title "Assignment Partial" -Message $errText
            }
            else {
                $groupNames = ($selectedGroups | ForEach-Object { $_.GroupName }) -join ", "
                $appNamesList = ($SelectedApps | Select-Object -First 3 -ExpandProperty DisplayName) -join ", "
                if ($SelectedApps.Count -gt 3) { $appNamesList += " (+$($SelectedApps.Count - 3) more)" }
                $confirmMsg = "Successfully assigned $($selectedGroups.Count) group(s) to $($SelectedApps.Count) app(s) as '$intent'.`n`nApps: $appNamesList`n`nGroups: $groupNames"
                Show-AppPopup -Title "Assignment Complete" -Message $confirmMsg
            }
        })

        # Remove all assignments from selected apps via Graph DELETE on each assignment
        $btnRemoveAssignments.Add_Click({
            $appNamesList = ($SelectedApps | Select-Object -First 3 -ExpandProperty DisplayName) -join ", "
            if ($SelectedApps.Count -gt 3) { $appNamesList += " (+$($SelectedApps.Count - 3) more)" }

            $confirmed = Show-ConfirmPopup `
                -Title        "Remove Assignments" `
                -Message      "This will remove ALL assignments from $($SelectedApps.Count) app(s):`n`n$appNamesList" `
                -ConfirmLabel "Remove" `
                -CancelLabel  "Cancel"
            if (-not $confirmed) { return }

            $txtAssignmentStatus.Text = "Removing assignments..."
            $btnRemoveAssignments.IsEnabled = $false

            $errors = @()
            $succeeded = 0

            foreach ($app in $SelectedApps) {
                try {
                    # Fetch existing assignments, then DELETE each one individually
                    $listUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.Id)/assignments"
                    $existing = Invoke-GraphGet -Uri $listUri
                    $existingList = @($existing.value)

                    foreach ($assignment in $existingList) {
                        $deleteUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.Id)/assignments/$($assignment.id)"
                        Invoke-GraphDelete -Uri $deleteUri
                    }

                    $app.AssignedGroups   = ""
                    $app.AssignmentIntent = ""
                    $app.Status           = "Not Assigned"
                    $app.AssignmentCount  = 0
                    $succeeded++

                    Write-UILogWithTimestamp -Message "Removed $($existingList.Count) assignment(s) from: $($app.DisplayName)" -Level "SUCCESS"
                }
                catch {
                    $errMsg = $_.Exception.Message
                    $errors += "$($app.DisplayName): $errMsg"
                    Write-UILogWithTimestamp -Message "Remove failed for $($app.DisplayName): $errMsg" -Level "ERROR"
                }
            }

            $dgApps.Items.Refresh()
            $txtStatus.Text = "Ready"
            $AssignWindow.Close()

            if ($errors.Count -gt 0) {
                $errText = "Removed assignments from $succeeded of $($SelectedApps.Count) app(s).`n`nErrors:`n" + ($errors -join "`n")
                Show-AppPopup -Title "Remove Partial" -Message $errText
            }
            else {
                $removeMsg = "Successfully removed all assignments from $($SelectedApps.Count) app(s).`n`nApps: $appNamesList"
                Show-AppPopup -Title "Assignments Removed" -Message $removeMsg
            }
        })

        # Copy From App button — pre-select groups from another app's assignment
        $btnCopyFrom.Add_Click({
            $appsWithAssignments = @($Script:GridData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.AssignedGroups) } | Sort-Object DisplayName)
            if ($appsWithAssignments.Count -eq 0) {
                Show-AppPopup -Title "No Assigned Apps" -Message "No apps with existing assignments found to copy from."
                return
            }

            $pickerXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Copy Assignments From"
        WindowStartupLocation="CenterOwner"
        SizeToContent="Height" Width="520"
        MinHeight="180" MaxHeight="460"
        ResizeMode="NoResize"
        Background="#F3F6FB" FontFamily="Segoe UI">
    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Select a source application to copy its group assignments:" FontWeight="SemiBold" FontSize="13" Foreground="#1B2430" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <ComboBox Name="cmbPickApp" Grid.Row="1" Height="36" FontSize="12.5" BorderBrush="#D9DEE6" Background="White" VerticalContentAlignment="Center" Margin="0,0,0,16"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnPickCancel" Content="Cancel" Width="90" Height="36" Cursor="Hand" Margin="0,0,10,0" FontSize="13" FontWeight="SemiBold" Foreground="#1B2430">
                <Button.Template><ControlTemplate TargetType="Button"><Border x:Name="bd" Background="White" BorderBrush="#D9DEE6" BorderThickness="1" CornerRadius="18" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,0"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#EEF2F8"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template>
            </Button>
            <Button Name="btnPickOk" Content="Copy" Width="90" Height="36" Cursor="Hand" IsDefault="True" FontSize="13" FontWeight="SemiBold" Foreground="White">
                <Button.Template><ControlTemplate TargetType="Button"><Border x:Name="bd" Background="#1F6FEB" CornerRadius="18" SnapsToDevicePixels="True"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,0"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#3A82F2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Button.Template>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@
            try {
                $pickerReader = New-Object System.Xml.XmlNodeReader ([xml]$pickerXaml)
                $pickerWin = [Windows.Markup.XamlReader]::Load($pickerReader)
                $pickerWin.Owner = $AssignWindow
                $cmbPickApp = $pickerWin.FindName("cmbPickApp")
                foreach ($a in $appsWithAssignments) {
                    $pItem = New-Object System.Windows.Controls.ComboBoxItem
                    $pItem.Content = "$($a.DisplayName)  [$($a.AssignmentIntent)]"
                    $pItem.Tag = $a
                    $cmbPickApp.Items.Add($pItem) | Out-Null
                }
                $cmbPickApp.SelectedIndex = 0
                $pickerWin.FindName("btnPickCancel").Add_Click({ $pickerWin.DialogResult = $false; $pickerWin.Close() })
                $pickerWin.FindName("btnPickOk").Add_Click({
                    $sel = $cmbPickApp.SelectedItem
                    if ($sel) {
                        $src = $sel.Tag
                        $srcGroups = $src.AssignedGroups -split ";\s*"
                        foreach ($grpObj in $lstAvailableGroups.Items) {
                            $grpObj.IsSelected = ($srcGroups -contains $grpObj.GroupName)
                        }
                        $lstAvailableGroups.Items.Refresh()
                        $srcIntent = [string]$src.AssignmentIntent
                        if ($srcIntent -like "*Required*")  { $rdoRequired.IsChecked  = $true }
                        elseif ($srcIntent -like "*Available*") { $rdoAvailable.IsChecked = $true }
                        elseif ($srcIntent -like "*Uninstall*") { $rdoUninstall.IsChecked = $true }
                        Write-UILogWithTimestamp -Message "Copied assignment config from: $($src.DisplayName)" -Level "INFO"
                    }
                    $pickerWin.DialogResult = $true; $pickerWin.Close()
                })
                $pickerWin.ShowDialog() | Out-Null
            }
            catch {
                Write-UILogWithTimestamp -Message "Copy From error: $($_.Exception.Message)" -Level "ERROR"
            }
        })

        $btnCancel.Add_Click({
            $AssignWindow.Close()
        })

        $AssignWindow.Owner = $Window
        $AssignWindow.ShowDialog() | Out-Null
    }
    catch {
        Write-UILogWithTimestamp -Message "Error opening assignment window: $($_.Exception.Message)" -Level "ERROR"
    }
}

#endregion

#region Event Handlers

# Connect Button
$btnConnect.Add_Click({
    try {
        if (-not $Script:IsConnected) {
            $txtStatus.Text = "Connecting to Intune..."
            Write-UILogWithTimestamp -Message "Connecting to Intune..." -Level "INFO"
            [System.Windows.Forms.Application]::DoEvents() | Out-Null

            Write-UILogWithTimestamp -Message "Fetching connection info..." -Level "INFO"
            if (Connect-Intune) {
                $Info = Get-ConnectionInfo
                $txtTenantName.Text = $Info.TenantName
                $txtTenantId.Text = $Info.TenantId
                $txtUser.Text = $Info.User
                $Script:IsConnected = $true
                $btnConnect.Content = "Logout"

                $btnRefresh.IsEnabled = $true
                $btnExport.IsEnabled = $true
                $btnBackup.IsEnabled = $true
                $btnDelete.IsEnabled = $true
                $btnAssignGroups.IsEnabled = $true
                $btnViewDetails.IsEnabled = $true
                $btnOpenPortal.IsEnabled = $true
                $btnExportAssignments.IsEnabled = $true

                Write-UILogWithTimestamp -Message "Connected to tenant: $($Info.TenantName)" -Level "SUCCESS"
                $statSyncStatus.Text = "In Sync"

                # Log before/after loading to avoid "looks frozen"
                Write-UILogWithTimestamp -Message "Loading Win32 apps into grid..." -Level "INFO"
                [System.Windows.Forms.Application]::DoEvents() | Out-Null
                Load-Apps
                Write-UILogWithTimestamp -Message "Win32 app grid loaded." -Level "SUCCESS"
            }
            else {
                Write-UILogWithTimestamp -Message "Connect-Intune returned false." -Level "ERROR"
                $txtStatus.Text = "Connection failed"
            }
        }
        else {
            Write-UILogWithTimestamp -Message "Disconnecting from Intune..." -Level "INFO"
            Disconnect-Intune
            $Script:IsConnected = $false
            $btnConnect.Content = "Connect To Intune"
            $btnRefresh.IsEnabled = $false
            $btnExport.IsEnabled = $false
            $btnBackup.IsEnabled = $false
            $btnDelete.IsEnabled = $false
            $btnAssignGroups.IsEnabled = $false
            $btnViewDetails.IsEnabled = $false
            $btnOpenPortal.IsEnabled = $false
            $btnExportAssignments.IsEnabled = $false

            $txtTenantName.Text = "Not Connected"
            $txtTenantId.Text = ""
            $txtUser.Text = ""
            $Script:GridData = @()
            $dgApps.ItemsSource = $null
            $pbProgress.Value = 0
            $txtProgress.Text = "0%"
            $statSyncStatus.Text = "Not Connected"

            Write-UILogWithTimestamp -Message "Disconnected from Intune" -Level "SUCCESS"
            $Window.Title = "Intune Win32 Bulk Management"
        }
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
        $txtStatus.Text = "Connection error"
    }
})

# Refresh Button
$btnRefresh.Add_Click({
    Write-UILogWithTimestamp -Message "Refreshing application list..." -Level "INFO"
    Load-Apps
})

# Assign Groups Button
$btnAssignGroups.Add_Click({
    try {
        # Do NOT rely on $Script:GridData being updated by the checkbox TwoWay binding.
        # Instead, read the actual item objects currently bound to the grid.
        $gridItems = @($dgApps.ItemsSource)
        $SelectedApps = $gridItems | Where-Object { $_.Selected -eq $true }

        if ($SelectedApps.Count -eq 0) {
            Write-UILogWithTimestamp -Message "No apps selected for group assignment (checked items found: 0)" -Level "WARN"
            Show-AppPopup -Title "No Apps Selected" -Message "Please select one or more apps to assign groups"
            return
        }

        # Log a sample for debugging
        $sample = ($SelectedApps | Select-Object -First 3 | ForEach-Object { "$($_.DisplayName)" }) -join ", "
        Write-UILogWithTimestamp -Message "Assign groups for $($SelectedApps.Count) app(s). Sample: $sample" -Level "INFO"

        # Pass only currently-selected apps into the assignment window.
        Show-AssignmentWindow -SelectedApps $SelectedApps
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
    }
})

# View Details Button
$btnViewDetails.Add_Click({
    try {
        $gridItems = @($dgApps.ItemsSource)
        $SelectedApp = $gridItems | Where-Object { $_.Selected -eq $true } | Select-Object -First 1

        if (-not $SelectedApp) {
            Show-AppPopup -Title "App Details" -Message "Check the checkbox next to an app to view its details"
            return
        }

        Show-AppDetailsPopup -App $SelectedApp
        Write-UILogWithTimestamp -Message "Viewed details for: $($SelectedApp.DisplayName)" -Level "INFO"
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
    }
})

# Select All Checkbox
$chkSelectAll.Add_Click({
    $IsChecked = $chkSelectAll.IsChecked
    foreach ($App in $Script:GridData) {
        $App.Selected = $IsChecked
    }
    $dgApps.Items.Refresh()
    Update-SelectedCount
})

# Force card/stat refresh after checkbox clicks only.
# PreviewMouseUp fires for every DataGrid click, so walk the visual tree to confirm
# the click originated on a CheckBox before logging or refreshing.
$dgApps.Add_PreviewMouseUp({
    param($sender, $e)
    try {
        $el = $e.OriginalSource
        $hitCheckBox = $false
        while ($null -ne $el) {
            if ($el -is [System.Windows.Controls.CheckBox]) { $hitCheckBox = $true; break }
            try { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) } catch { break }
        }
        if (-not $hitCheckBox) { return }

        $Window.Dispatcher.Invoke([action]{
            Start-Sleep -Milliseconds 30
            Write-UILogWithTimestamp -Message "Selection updated (checkbox toggled)" -Level "INFO"
            Update-SelectAllCheckbox
            Update-SelectedCount
            $dgApps.Items.Refresh()
        }) | Out-Null
    }
    catch {
        Write-UILogWithTimestamp -Message "PreviewMouseUp refresh error: $($_.Exception.Message)" -Level "ERROR"
    }
})

# Data Grid selection changed (fallback)
$dgApps.Add_SelectionChanged({
    Update-SelectAllCheckbox
    Update-SelectedCount
})

# DataGrid GotFocus: whenever a SelectableCell TextBox gains focus (e.g. after our
# double-click handler calls Focus()), attach a one-time SelectionChanged handler that
# copies the selected text to the clipboard immediately — so the text is available for
# pasting even after the highlight visually disappears on focus loss (WPF limitation).
$Script:__CellSelHandled = [System.Collections.Generic.HashSet[object]]::new()
$dgApps.Add_GotFocus({
    param($sender, $e)
    $tb = $e.OriginalSource
    if ($tb -isnot [System.Windows.Controls.TextBox]) { return }
    if ($Script:__CellSelHandled.Contains($tb)) { return }
    [void]$Script:__CellSelHandled.Add($tb)
    $tb.Add_SelectionChanged({
        param($s, $ev)
        if ($s.SelectionLength -gt 0) {
            try { [System.Windows.Clipboard]::SetText($s.SelectedText) } catch {}
        }
    })
})

# Horizontal scroll via vertical mouse wheel:
#   Shift+Wheel anywhere on the DataGrid → horizontal scroll.
#   Plain wheel when cursor is over the horizontal scrollbar strip → horizontal scroll.
# ActualHeight is in pixels; ViewportHeight is in logical row-count units so it cannot
# be used as a pixel threshold — always compare pixels to pixels.
$dgApps.Add_PreviewMouseWheel({
    param($sender, $e)
    try {
        $sv = $Script:DgScrollViewer
        if ($null -eq $sv) {
            try { $sv = $sender.Template.FindName("DG_ScrollViewer", $sender) } catch {}
        }
        if ($null -eq $sv -or $sv.ScrollableWidth -le 0) { return }

        $shiftHeld = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift

        # Cursor below the scrollable content (bottom 16px of the ScrollViewer = scrollbar strip).
        # Both posInSv.Y and sv.ActualHeight are in pixels — safe to compare.
        $overHBar = $false
        try {
            $posInSv = $e.GetPosition($sv)
            $overHBar = ($posInSv.Y -ge ($sv.ActualHeight - 16))
        } catch {}

        if ($shiftHeld -or $overHBar) {
            $e.Handled = $true
            if ($e.Delta -gt 0) { $sv.LineLeft() } else { $sv.LineRight() }
        }
    } catch {}
})
# WM_MOUSEHWHEEL (touchpad horizontal swipe, tilt wheel) is handled in C# via HwndHook —
# wired up in $Window.Add_Loaded after the ScrollViewer is found.

# DataGrid double-click → select all text in the clicked cell's TextBox.
# Two complementary triggers (belt-and-suspenders):
#   1. Window PreviewMouseLeftButtonDown (ClickCount=2) — fires during the DOWN of click 2.
#   2. DataGrid MouseDoubleClick — fires after WPF word-selection has already run.
# Both use a 100 ms DispatcherTimer so SelectAll() lands after every WPF mouse-event
# processing is complete.  IsInactiveSelectionHighlightEnabled=True (set in the Style)
# keeps the highlight visible even after the TextBox loses keyboard focus.

$Script:__SelectTextBox = {
    param($el)
    if ($null -eq $el) { return }
    [WpfTextHelper]::SelectAllDeferred($el, 100)
}

$Script:__FindTextBoxAncestor = {
    param($start)
    $el = $start
    while ($null -ne $el) {
        if ($el -is [System.Windows.Controls.TextBox]) { return $el }
        try { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) } catch { return $null }
    }
    return $null
}

# Trigger 1: PreviewMouseLeftButtonDown (tunneling — fires first, before DataGrid row-select)
$Window.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    if ($e.ClickCount -ne 2) { return }
    $tb = & $Script:__FindTextBoxAncestor $e.OriginalSource
    if ($null -ne $tb) { & $Script:__SelectTextBox $tb }
})

# Trigger 2: DataGrid MouseDoubleClick (bubbling — fires after WPF word-select, so timer
# gives SelectAll() the last word after ALL internal double-click processing completes)
$dgApps.Add_MouseDoubleClick({
    param($sender, $e)
    $tb = & $Script:__FindTextBoxAncestor $e.OriginalSource
    if ($null -ne $tb) { & $Script:__SelectTextBox $tb }
})


# Search
$txtSearch.Add_TextChanged({
    try { Apply-GridFilter }
    catch { Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR" }
})

# Status filter
$cmbStatusFilter.Add_SelectionChanged({
    try { Apply-GridFilter }
    catch { Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR" }
})

# Publisher filter
$cmbPublisherFilter.Add_SelectionChanged({
    try { Apply-GridFilter }
    catch { Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR" }
})

# Open in Intune Portal
$btnOpenPortal.Add_Click({
    try {
        $gridItems = @($dgApps.ItemsSource)
        $app = $gridItems | Where-Object { $_.Selected -eq $true } | Select-Object -First 1
        if (-not $app) {
            Show-AppPopup -Title "No App Selected" -Message "Select an app row to open it in the Intune Portal."
            return
        }
        Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.Id)"
        Write-UILogWithTimestamp -Message "Opened in Intune Portal: $($app.DisplayName)" -Level "INFO"
    }
    catch {
        Write-UILogWithTimestamp -Message "Open Portal error: $($_.Exception.Message)" -Level "ERROR"
    }
})

# Export Assignments CSV
$btnExportAssignments.Add_Click({
    try {
        if (-not $Script:IsConnected) {
            Show-AppPopup -Title "Not Connected" -Message "Connect to Intune before exporting assignments."
            return
        }
        $Dialog = New-Object Microsoft.Win32.SaveFileDialog
        $Dialog.Filter = "CSV Files (*.csv)|*.csv"
        $Dialog.FileName = "IntuneAssignments_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        if ($Dialog.ShowDialog()) {
            Write-UILogWithTimestamp -Message "Exporting assignment report..." -Level "INFO"
            $txtStatus.Text = "Exporting assignments..."
            $rows = @()
            foreach ($a in $Script:GridData) {
                if (-not [string]::IsNullOrWhiteSpace($a.AssignedGroups)) {
                    $groups  = $a.AssignedGroups   -split ";\s*"
                    $intents = $a.AssignmentIntent -split "\s*/\s*"
                    for ($i = 0; $i -lt $groups.Count; $i++) {
                        $rows += [PSCustomObject]@{
                            AppName   = $a.DisplayName
                            AppId     = $a.Id
                            Publisher = $a.Publisher
                            Version   = $a.Version
                            Group     = $groups[$i].Trim()
                            Intent    = if ($intents.Count -gt $i) { $intents[$i].Trim() } else { $a.AssignmentIntent }
                            Status    = $a.Status
                        }
                    }
                }
                else {
                    $rows += [PSCustomObject]@{
                        AppName   = $a.DisplayName
                        AppId     = $a.Id
                        Publisher = $a.Publisher
                        Version   = $a.Version
                        Group     = "Not Assigned"
                        Intent    = ""
                        Status    = $a.Status
                    }
                }
            }
            $rows | Export-Csv -Path $Dialog.FileName -NoTypeInformation -Encoding UTF8
            Write-UILogWithTimestamp -Message "Assignment report saved: $($Dialog.FileName)" -Level "SUCCESS"
            $txtStatus.Text = "Assignments exported"
        }
    }
    catch {
        Write-UILogWithTimestamp -Message "Export Assignments error: $($_.Exception.Message)" -Level "ERROR"
    }
})


# Delete Button
$btnDelete.Add_Click({
    try {
        $SelectedApps = $Script:GridData | Where-Object { $_.Selected -eq $true }
        
        if ($SelectedApps.Count -eq 0) {
            Write-UILogWithTimestamp -Message "Delete attempted with no apps selected" -Level "WARN"
            return
        }
        
        $Result = $false
        # Use themed popup for confirmations
        # (simple: treat OK as "Yes", Cancel as "No" not supported in this minimal dialog)
        Show-AppPopup -Title "Confirm" -Message ("Delete {0} selected apps?" -f $SelectedApps.Count)
        $Result = $true
        
        if ($Result -eq "Yes") {
            Write-UILogWithTimestamp -Message "Deleting $($SelectedApps.Count) app(s)..." -Level "INFO"
                $txtStatus.Text = "Deleting apps..."
            
            if (Remove-SelectedApps -Apps $SelectedApps -ProgressBar $pbProgress -ProgressLabel $txtProgress) {
                Write-UILogWithTimestamp -Message "$($SelectedApps.Count) app(s) deleted successfully" -Level "SUCCESS"
                Load-Apps
            }
        }
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
    }
})

# Export Button
$btnExport.Add_Click({
    try {
        $Dialog = New-Object Microsoft.Win32.SaveFileDialog
        $Dialog.Filter = "CSV Files (*.csv)|*.csv"
        $Dialog.FileName = "IntuneApps.csv"
        
        if ($Dialog.ShowDialog()) {
            $txtStatus.Text = "Exporting to CSV..."
            Write-UILogWithTimestamp -Message "Exporting to CSV: $($Dialog.FileName)" -Level "INFO"
            
            Export-AppsToCsv -Apps $Script:GridData -Path $Dialog.FileName
            Write-UILogWithTimestamp -Message "Export completed successfully" -Level "SUCCESS"
            $txtStatus.Text = "Export completed"
        }
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
    }
})

# Backup Button
$btnBackup.Add_Click({
    try {
        $Dialog = New-Object Microsoft.Win32.SaveFileDialog
        $Dialog.Filter = "JSON Files (*.json)|*.json"
        $Dialog.FileName = "IntuneAppsBackup.json"
        
        if ($Dialog.ShowDialog()) {
            $txtStatus.Text = "Creating backup..."
            Write-UILogWithTimestamp -Message "Creating backup: $($Dialog.FileName)" -Level "INFO"
            
            Backup-AppsToJson -Apps $Script:GridData -Path $Dialog.FileName
            Write-UILogWithTimestamp -Message "Backup completed successfully" -Level "SUCCESS"
            $txtStatus.Text = "Backup completed"
        }
    }
    catch {
        Write-UILogWithTimestamp -Message $_.Exception.Message -Level "ERROR"
    }
})

# Clear Log Button
$btnClearLog.Add_Click({
    $txtLog.Clear()
    Write-UILogWithTimestamp -Message "Log cleared" -Level "INFO"
})

#endregion

#region Initialize

$btnRefresh.IsEnabled = $false
$btnExport.IsEnabled = $false
$btnBackup.IsEnabled = $false
$btnDelete.IsEnabled = $false
$btnAssignGroups.IsEnabled = $false
$btnViewDetails.IsEnabled = $false
$btnOpenPortal.IsEnabled = $false
$btnExportAssignments.IsEnabled = $false

# Load persisted settings (window size, filter state, refresh interval)
Load-AppSettings

Write-UILogWithTimestamp -Message "Application started - Ready to connect" -Level "INFO"
$txtStatus.Text = "Ready"

#endregion

#region Show Window

# Track which monitor the window is currently on so we only act on a real monitor change
$Script:CurrentMonitorName = ""

# Debounce timer: fires 350 ms after the user STOPS dragging.
# Using DispatcherTimer keeps everything on the UI thread — no cross-thread issues.
$Script:MonitorTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:MonitorTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$Script:MonitorTimer.Add_Tick({
    $Script:MonitorTimer.Stop()
    try {
        $screen = Get-CurrentScreen
        if ($null -eq $screen) { return }
        if ($screen.DeviceName -ne $Script:CurrentMonitorName) {
            $Script:CurrentMonitorName = $screen.DeviceName
            # Resize to fit new monitor; preserve user's chosen position (no force-center)
            Fit-WindowToScreen -Screen $screen
        }
    } catch { }
})

# Cache the DataGrid's internal ScrollViewer once the template is fully applied.
# Template.FindName only works reliably after Loaded — not during construction.
$Script:DgScrollViewer = $null
$Window.Add_Loaded({
    $Script:DgScrollViewer = $dgApps.Template.FindName("DG_ScrollViewer", $dgApps)
    if ($null -eq $Script:DgScrollViewer) {
        # Fallback: BFS visual tree to find the first ScrollViewer inside the DataGrid
        $q = [System.Collections.Generic.Queue[object]]::new()
        $q.Enqueue($dgApps)
        while ($q.Count -gt 0 -and $null -eq $Script:DgScrollViewer) {
            $cur = $q.Dequeue()
            if ($cur -is [System.Windows.Controls.ScrollViewer]) { $Script:DgScrollViewer = $cur; break }
            $cnt = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($cur)
            for ($i = 0; $i -lt $cnt; $i++) {
                try { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($cur, $i)) } catch {}
            }
        }
    }
    # Wire WM_MOUSEHWHEEL hook (touchpad horizontal swipe, tilt wheel) via C# HwndHook.
    # Loaded fires after SourceInitialized so the window handle is guaranteed to exist.
    try {
        $hwndSrc = [System.Windows.Interop.HwndSource]::FromDependencyObject($Window)
        if ($null -eq $hwndSrc) {
            Write-UILog -Message "Horizontal scroll hook: HwndSource unavailable — touchpad/tilt-wheel scroll disabled." -Level ERROR
        } elseif ($null -eq $Script:DgScrollViewer) {
            Write-UILog -Message "Horizontal scroll hook: DataGrid ScrollViewer not found — touchpad/tilt-wheel scroll disabled." -Level ERROR
        } else {
            [WpfTextHelper]::HookHorizontalWheel($hwndSrc, $Script:DgScrollViewer)
        }
    } catch {
        Write-UILog -Message "Horizontal scroll hook failed: $($_.Exception.Message)" -Level ERROR
    }
})

# Initial fit + center when the window handle exists
$Window.Add_SourceInitialized({
    Fit-WindowToScreen -Center
    $s = Get-CurrentScreen
    if ($null -ne $s) { $Script:CurrentMonitorName = $s.DeviceName }
})

# Save settings when closing
$Window.Add_Closing({
    Save-AppSettings
})

# LocationChanged fires every frame during a drag — DO NOT reposition here.
# Just (re)start the debounce timer so the resize only happens after the drag ends.
$Window.Add_LocationChanged({
    $Script:MonitorTimer.Stop()
    $Script:MonitorTimer.Start()
}) | Out-Null

$Window.ShowDialog() | Out-Null

#endregion
