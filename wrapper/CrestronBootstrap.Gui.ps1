<#
.SYNOPSIS
    WPF GUI for CrestronAdminBootstrap. Single window, 6 tabs, status bar.

.DESCRIPTION
    Scaffolding pass: window opens, tabs render, status bar shows workspace
    path + credential state, close button works. Tab content is filled in by
    later builds.

    Runs under PowerShell 7. Launched by CrestronBootstrap.exe (bootstrapper)
    or directly via:
        pwsh -NoProfile -ExecutionPolicy Bypass -File .\CrestronBootstrap.Gui.ps1 -WorkingDirectory C:\some\path
#>
[CmdletBinding()]
param(
    [string]$WorkingDirectory = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# ---- Sanity checks -----------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    [System.Windows.Forms.MessageBox]::Show(
        "CrestronAdminBootstrap GUI requires PowerShell 7+.",
        "Wrong PowerShell version", 'OK', 'Error'
    ) | Out-Null
    exit 1
}

# Normalize working directory to an absolute path
if (-not [IO.Path]::IsPathRooted($WorkingDirectory)) {
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

# Load WPF assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Module
if (-not (Get-Module -ListAvailable CrestronAdminBootstrap)) {
    [System.Windows.MessageBox]::Show(
        "CrestronAdminBootstrap module is not installed. Run the installer first:`n`niex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)",
        "Module missing", 'OK', 'Error'
    ) | Out-Null
    exit 1
}
Import-Module CrestronAdminBootstrap -Force

# ---- App-wide state ----------------------------------------------------------
$Script:AppState = [pscustomobject]@{
    WorkspaceDirectory = $WorkingDirectory
    Credential         = $null              # cached [pscredential]
    ScanCsv            = Join-Path $WorkingDirectory 'crestron-bootup.csv'
    ProvisionCsv       = Join-Path $WorkingDirectory 'crestron-provisioned.csv'
    VerifyCsv          = Join-Path $WorkingDirectory 'crestron-verified.csv'
    SettingsCsv        = Join-Path $WorkingDirectory 'crestron-settings.csv'
    PerDeviceCsv       = Join-Path $WorkingDirectory 'crestron-perdevice.csv'
    GuiSettingsJson    = Join-Path $WorkingDirectory 'gui-settings.json'
    SubnetsFile        = Join-Path $WorkingDirectory 'subnets.txt'
}

function New-DefaultGuiSettings {
    [pscustomobject]@{
        DefaultUsername          = ''
        ProtectedDefaultPassword = ''
        DarkMode                 = $false
        MostUsedSubnets          = @(
            '172.22.0.0/24'
        )
    }
}

function Protect-GuiSettingPassword {
    param(
        [string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($Password)) {
        return ''
    }

    try {
        return ConvertFrom-SecureString (ConvertTo-SecureString $Password -AsPlainText -Force)
    }
    catch {
        return ''
    }
}

function Unprotect-GuiSettingPassword {
    param(
        [string]$ProtectedPassword
    )

    if ([string]::IsNullOrWhiteSpace($ProtectedPassword)) {
        return ''
    }

    try {
        $secure = ConvertTo-SecureString $ProtectedPassword
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }
    catch {
        return ''
    }
}

function Load-GuiSettings {
    $settings = New-DefaultGuiSettings

    if (-not (Test-Path $Script:AppState.GuiSettingsJson)) {
        $Script:GuiSettings = $settings
        return
    }

    try {
        $loaded = Get-Content $Script:AppState.GuiSettingsJson -Raw | ConvertFrom-Json

        if ($loaded.DefaultUsername) {
            $settings.DefaultUsername = "$($loaded.DefaultUsername)"
        }

        if ($loaded.ProtectedDefaultPassword) {
            $settings.ProtectedDefaultPassword = "$($loaded.ProtectedDefaultPassword)"
        }

        if ($loaded.PSObject.Properties.Name -contains 'MostUsedSubnets' -and $loaded.MostUsedSubnets) {
            $loadedSubnets = @($loaded.MostUsedSubnets | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })

            if ($loadedSubnets.Count -gt 0) {
                $settings.MostUsedSubnets = $loadedSubnets
            }
        }

        $settings.DarkMode = [bool]$loaded.DarkMode
    }
    catch {
        $settings = New-DefaultGuiSettings
    }

    $Script:GuiSettings = $settings
}

function Save-GuiSettings {
    if (-not $Script:GuiSettings) {
        $Script:GuiSettings = New-DefaultGuiSettings
    }

    $Script:GuiSettings |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $Script:AppState.GuiSettingsJson -Encoding UTF8
}

Load-GuiSettings

# ---- XAML --------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Crestron Admin Bootstrap"
        Width="1100" Height="750"
        MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen">
    <DockPanel LastChildFill="True">

        <!-- Status bar (docked bottom) -->
        <StatusBar DockPanel.Dock="Bottom" Height="28">
            <StatusBarItem>
                <TextBlock x:Name="StatusText" Text="Idle" Foreground="#CC0000" FontWeight="Bold" />
            </StatusBarItem>
            <Separator />
            <StatusBarItem>
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Workspace: " Foreground="#666" />
                    <TextBlock x:Name="WorkspaceText" Cursor="Hand" Foreground="#0066CC"
                               TextDecorations="Underline" />
                </StackPanel>
            </StatusBarItem>
            <Separator />
            <StatusBarItem>
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Credentials: " Foreground="#666" />
                    <TextBlock x:Name="CredText" Text="not entered" />
                    <Button x:Name="ForgetCredButton" Content="Clear" Margin="8,0,0,0"
                            Padding="6,1" FontSize="11" />
                </StackPanel>
            </StatusBarItem>
        </StatusBar>

        <!-- Main tabs (fills remaining space) -->
        <TabControl x:Name="MainTabs" Margin="6">
            <TabItem Header="Full Workflow" x:Name="WorkflowTab">
                <DockPanel Margin="12">

                    <!-- Top: title + action -->
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,12">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock Text="Full Workflow" FontSize="18" FontWeight="Bold" />
                            <TextBlock Text="Runs Scan → Provision → Blanket Settings → Per-Device → Reboot → Verify in sequence." Foreground="#666" />
                        </StackPanel>
                        <Button x:Name="WorkflowStartButton"   Grid.Column="1" Content="Start Workflow"    Padding="16,6" FontWeight="Bold" />
                        <Button x:Name="WorkflowContinueButton" Grid.Column="2" Content="Continue Workflow" Padding="14,6" Margin="8,0,0,0" IsEnabled="False" />
                        <Button x:Name="WorkflowCancelButton"  Grid.Column="3" Content="Cancel"             Padding="14,6" Margin="8,0,0,0" IsEnabled="False" />
                    </Grid>

                    <!-- Bottom status -->
                    <TextBlock x:Name="WorkflowStatusText" DockPanel.Dock="Bottom" Margin="0,12,0,0" Foreground="#666" Text="Workflow not running." />

                    <!-- Live reboot status grid (visible only during the wait step) -->
                    <Border x:Name="WorkflowRebootPanel" DockPanel.Dock="Bottom" BorderBrush="#DDD" BorderThickness="1"
                            Padding="10" Margin="0,12,0,0" Height="220" Visibility="Collapsed">
                        <DockPanel LastChildFill="True">
                            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
                                <TextBlock Text="Reboot wait" FontWeight="Bold" />
                                <TextBlock x:Name="WorkflowCountdownText" Margin="16,0,0,0" Foreground="#0066CC" FontFamily="Consolas" />
                                <TextBlock x:Name="WorkflowOnlineText"    Margin="16,0,0,0" Foreground="#666" />
                            </StackPanel>
                            <DataGrid x:Name="WorkflowRebootGrid"
                                      AutoGenerateColumns="False"
                                      CanUserAddRows="False"
                                      CanUserDeleteRows="False"
                                      HeadersVisibility="Column"
                                      GridLinesVisibility="Horizontal"
                                      AlternatingRowBackground="#F8F8F8"
                                      IsReadOnly="True">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="IP"            Binding="{Binding IP}"           Width="140" />
                                    <DataGridTextColumn Header="Status"        Binding="{Binding Status}"       Width="100" />
                                    <DataGridTextColumn Header="First Online"  Binding="{Binding FirstOnlineAt}" Width="160" />
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <!-- Step list -->
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <ItemsControl x:Name="WorkflowStepsList">
                            <ItemsControl.ItemTemplate>
                                <DataTemplate>
                                    <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,6">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="40" />
                                                <ColumnDefinition Width="200" />
                                                <ColumnDefinition Width="*" />
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="{Binding Icon}"   FontSize="20" VerticalAlignment="Center" />
                                            <TextBlock Grid.Column="1" Text="{Binding Title}"  FontWeight="Bold" VerticalAlignment="Center" />
                                            <TextBlock Grid.Column="2" Text="{Binding Detail}" Foreground="#444" VerticalAlignment="Center" TextWrapping="Wrap" />
                                        </Grid>
                                    </Border>
                                </DataTemplate>
                            </ItemsControl.ItemTemplate>
                        </ItemsControl>
                    </ScrollViewer>

                </DockPanel>
            </TabItem>
            <TabItem Header="Scan">
                <DockPanel Margin="8">

                    <!-- Subnets panel (left) -->
                    <Border DockPanel.Dock="Left" Width="320" BorderBrush="#DDD" BorderThickness="1" Padding="8" Margin="0,0,8,0">
                        <DockPanel LastChildFill="True">
                            <TextBlock DockPanel.Dock="Top" Text="Subnets (CIDR)" FontWeight="Bold" Margin="0,0,0,4" />

                            <TextBlock DockPanel.Dock="Top"
                                    Text="Check subnet(s) to scan. Defaults come from Settings → Most Used Subnets."
                                    Foreground="#666"
                                    FontSize="11"
                                    TextWrapping="Wrap"
                                    Margin="0,0,0,8" />

                            <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="ScanCidrInput"
                                        Grid.Column="0"
                                        Padding="4,2"
                                        VerticalContentAlignment="Center" />
                                <Button x:Name="ScanAddCidr"
                                        Grid.Column="1"
                                        Content="Add"
                                        Margin="6,0,0,0"
                                        Padding="10,2" />
                            </Grid>

                            <Button x:Name="ScanRemoveCidr"
                                    DockPanel.Dock="Bottom"
                                    Content="Remove Checked"
                                    Margin="0,6,0,0"
                                    Padding="10,2" />

                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <StackPanel x:Name="ScanCidrList" />
                            </ScrollViewer>
                        </DockPanel>
                    </Border>

                    <!-- Results panel (right) -->
                    <DockPanel LastChildFill="True">

                        <!-- Action bar -->
                        <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto" />
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <Button x:Name="ScanStartButton" Grid.Column="0" Content="Start Scan" Padding="16,4" FontWeight="Bold" />
                            <TextBlock x:Name="ScanProgressText" Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#CC0000" FontWeight="Bold" />
                            <Button x:Name="ScanCancelButton" Grid.Column="2" Content="Cancel" Padding="12,4" IsEnabled="False" />
                        </Grid>

                        <!-- Summary line under grid -->
                        <Grid DockPanel.Dock="Bottom" Margin="0,6,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <TextBlock x:Name="ScanSummaryText" Grid.Column="0" Text="No scan yet." Foreground="#666" VerticalAlignment="Center" />
                            <CheckBox  x:Name="ScanSelectAll" Grid.Column="1" Content="Select all" />
                        </Grid>

                        <DataGrid x:Name="ScanResultsGrid"
                                  AutoGenerateColumns="False"
                                  CanUserAddRows="False"
                                  CanUserDeleteRows="False"
                                  HeadersVisibility="Column"
                                  GridLinesVisibility="Horizontal"
                                  SelectionMode="Extended"
                                  HorizontalScrollBarVisibility="Visible"
                                  AlternatingRowBackground="#F8F8F8">
                            <DataGrid.Columns>
                                <DataGridCheckBoxColumn Header="Sel" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40" />
                                <DataGridTextColumn Header="IP"          Binding="{Binding IP}"          Width="140" IsReadOnly="True" />
                                <DataGridTextColumn Header="MatchedSig"  Binding="{Binding MatchedSig}"  Width="220" IsReadOnly="True" />
                                <DataGridTextColumn Header="ScannedAt"   Binding="{Binding ScannedAt}"   Width="180" IsReadOnly="True" />
                            </DataGrid.Columns>
                        </DataGrid>
                    </DockPanel>

                </DockPanel>
            </TabItem>
            <TabItem Header="Provision" x:Name="ProvisionTab">
                <DockPanel Margin="8">

                    <!-- Action bar -->
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="ProvisionStartButton"  Grid.Column="0" Content="Provision Selected" Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="ProvisionReloadButton" Grid.Column="1" Content="Reload from scan CSV" Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="ProvisionRebootButton" Grid.Column="2" Content="Reboot Selected" Padding="10,4" Margin="8,0,0,0" HorizontalAlignment="Left" />
                        <TextBlock x:Name="ProvisionProgressText" Grid.Column="2" Margin="170,0,0,0" VerticalAlignment="Center" Foreground="#666" />
                        <Button x:Name="ProvisionCancelButton" Grid.Column="3" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <!-- Summary -->
                    <Grid DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="ProvisionSummaryText" Grid.Column="0" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                        <CheckBox  x:Name="ProvisionSelectAll" Grid.Column="1" Content="Select all" IsChecked="True" />
                    </Grid>

                    <DataGrid x:Name="ProvisionGrid"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              HorizontalScrollBarVisibility="Visible"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="Sel" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40" />
                            <DataGridTextColumn Header="IP"       Binding="{Binding IP}"       Width="140" IsReadOnly="True" />
                            <DataGridTextColumn Header="Status"   Binding="{Binding Status}"   Width="80"  IsReadOnly="True" />
                            <DataGridTextColumn Header="Success"  Binding="{Binding Success}"  Width="80"  IsReadOnly="True" />
                            <DataGridTextColumn Header="Response" Binding="{Binding Response}" Width="*"   IsReadOnly="True" />
                            <DataGridTextColumn Header="Time"     Binding="{Binding Timestamp}" Width="160" IsReadOnly="True" />
                        </DataGrid.Columns>
                    </DataGrid>

                </DockPanel>
            </TabItem>
            <TabItem Header="Blanket Settings" x:Name="BlanketTab">
                <DockPanel Margin="8">

                    <!-- Top: device grid -->
                    <Border DockPanel.Dock="Top" BorderBrush="#DDD" BorderThickness="1" Height="220" Margin="0,0,0,8">
                        <DockPanel LastChildFill="True">
                            <Grid DockPanel.Dock="Top" Margin="6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                    <ColumnDefinition Width="Auto" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="BlanketSummaryText" Grid.Column="0" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                                <Button x:Name="BlanketCapabilityButton" Grid.Column="1" Content="Fetch Capabilities" Padding="10,2" Margin="8,0,0,0" />
                                <CheckBox  x:Name="BlanketSelectAll"        Grid.Column="2" Content="Select all" IsChecked="True" Margin="8,0,0,0" />
                                <Button    x:Name="BlanketReloadButton"     Grid.Column="3" Content="Add Devices..." Padding="10,2" Margin="8,0,0,0" />
                            </Grid>

                            <ScrollViewer HorizontalScrollBarVisibility="Visible"
                                          VerticalScrollBarVisibility="Disabled">
                                <DataGrid x:Name="BlanketGrid"
                                          Width="1640"
                                          HorizontalAlignment="Left"
                                          AutoGenerateColumns="False"
                                          CanUserAddRows="False"
                                          CanUserDeleteRows="False"
                                          HeadersVisibility="Column"
                                          GridLinesVisibility="Horizontal"
                                          SelectionMode="Extended"
                                          ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                                          AlternatingRowBackground="#F8F8F8">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Sel" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40" />
                                    <DataGridTextColumn     Header="IP"            Binding="{Binding IP}"                  Width="140" IsReadOnly="True" />
                                    <DataGridTextColumn     Header="Model"         Binding="{Binding Model}"               Width="120" IsReadOnly="True" />
                                    <DataGridTextColumn     Header="Current Mode"  Binding="{Binding CurrentDeviceMode}"   Width="110" IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="AV?"           Binding="{Binding SupportsAvSettings}"  Width="55"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="EDID?"         Binding="{Binding SupportsGlobalEdid}"  Width="60"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="NTP?"          Binding="{Binding SupportsNtp}"         Width="55"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="Cloud?"        Binding="{Binding SupportsCloud}"       Width="65"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="Fusion?"       Binding="{Binding SupportsFusion}"      Width="65"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="Auto?"         Binding="{Binding SupportsAutoUpdate}"  Width="60"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="TX/RX Mode?"   Binding="{Binding SupportsModeChange}"  Width="70"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="Fetched?"      Binding="{Binding CapabilitiesFetched}" Width="75"  IsReadOnly="True" />
                                    <DataGridTextColumn     Header="Status"        Binding="{Binding Status}"              Width="90"  IsReadOnly="True" />
                                    <DataGridCheckBoxColumn Header="Reboot?"       Binding="{Binding NeedsReboot, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="70" />
                                    <DataGridTextColumn     Header="Sections"      Binding="{Binding Sections}"            Width="200" IsReadOnly="True" />
                                    <DataGridTextColumn     Header="Detail"        Binding="{Binding Detail}"              Width="260" IsReadOnly="True" />
                                    <DataGridTextColumn     Header="Time"          Binding="{Binding Timestamp}"           Width="160" IsReadOnly="True" />
                                </DataGrid.Columns>
                                </DataGrid>
                            </ScrollViewer>
                        </DockPanel>
                    </Border>

                    <!-- Bottom: settings sections + apply -->
                    <Grid DockPanel.Dock="Bottom" Margin="0,0,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BlanketApplyButton"  Grid.Column="0" Content="Apply to Selected" Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="BlanketRebootButton" Grid.Column="1" Content="Reboot Needed"     Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="BlanketClearButton"  Grid.Column="2" Content="Clear Loaded"      Padding="10,4" Margin="8,0,0,0" />
                        <TextBlock x:Name="BlanketProgressText" Grid.Column="3" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#CC0000" FontWeight="Bold" />
                        <Button x:Name="BlanketCancelButton" Grid.Column="4" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <!-- Middle (fills): settings sections -->
                    <ScrollViewer VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Auto">
                        <StackPanel Margin="0,0,0,8">

                            <!-- NTP / Time Zone -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                                <StackPanel>
                                    <CheckBox x:Name="NtpEnableBox" Content="Apply NTP / Time Zone" FontWeight="Bold" />
                                    <Grid Margin="20,8,0,0" IsEnabled="{Binding ElementName=NtpEnableBox, Path=IsChecked}">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto" />
                                            <ColumnDefinition Width="200" />
                                            <ColumnDefinition Width="Auto" />
                                            <ColumnDefinition Width="*" />
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto" />
                                            <RowDefinition Height="Auto" />
                                        </Grid.RowDefinitions>
                                        <TextBlock Text="NTP server"  Grid.Row="0" Grid.Column="0" Margin="0,0,8,4" VerticalAlignment="Center" />
                                        <TextBox   x:Name="NtpServerBox" Grid.Row="0" Grid.Column="1" Padding="4,2" Margin="0,0,0,4" Text="time.google.com" />
                                        <TextBlock Text="Time zone"   Grid.Row="1" Grid.Column="0" Margin="0,0,8,0" VerticalAlignment="Center" />
                                        <ComboBox  x:Name="NtpTimeZoneBox" Grid.Row="1" Grid.Column="1" Padding="4,2" />
                                    </Grid>
                                </StackPanel>
                            </Border>

                         <!-- Cloud Connection (XiO) -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                                <StackPanel>
                                    <CheckBox x:Name="CloudEnableBox" Content="Apply Cloud Connection (XiO) toggle" FontWeight="Bold" />
                                    <StackPanel Orientation="Horizontal" Margin="20,8,0,0" IsEnabled="{Binding ElementName=CloudEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="CloudOnRadio"  GroupName="CloudRadios" Content="Enable Cloud Connection"  IsChecked="True" Margin="0,0,16,0" />
                                        <RadioButton x:Name="CloudOffRadio" GroupName="CloudRadios" Content="Disable Cloud Connection" />
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <!-- Fusion Room -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                                <StackPanel>
                                    <CheckBox x:Name="FusionEnableBox" Content="Apply Fusion Room toggle" FontWeight="Bold" />
                                    <StackPanel Orientation="Horizontal" Margin="20,8,0,0" IsEnabled="{Binding ElementName=FusionEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="FusionOnRadio"  GroupName="FusionRadios" Content="Enable Fusion Room"  IsChecked="True" Margin="0,0,16,0" />
                                        <RadioButton x:Name="FusionOffRadio" GroupName="FusionRadios" Content="Disable Fusion Room" />
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                        <!-- Auto-Update -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                                <StackPanel>
                                    <CheckBox x:Name="AutoUpdateEnableBox"
                                              Content="Apply Auto-Update toggle"
                                              FontWeight="Bold" />

                                    <StackPanel Orientation="Horizontal"
                                                Margin="20,8,0,0"
                                                IsEnabled="{Binding ElementName=AutoUpdateEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="AutoUpdateOnRadio"
                                                     GroupName="AutoUpdateRadios"
                                                     Content="Enable Auto-Update"
                                                     IsChecked="True"
                                                     Margin="0,0,16,0" />
                                        <RadioButton x:Name="AutoUpdateOffRadio"
                                                     GroupName="AutoUpdateRadios"
                                                     Content="Disable Auto-Update" />
                                    </StackPanel>

                                    <TextBlock Margin="20,4,0,0"
                                               Foreground="#888"
                                               FontSize="11"
                                               TextWrapping="Wrap"
                                               Text="On TouchPanel devices only the on/off flag is sent; schedule/manifest fields are touchscreen-incompatible and are not exposed in the GUI." />
                                </StackPanel>
                            </Border>

                            <!-- DM-NVX Device Mode -->
                            <GroupBox Header="DM-NVX Device Mode" Margin="0,0,0,8" Padding="8">
                                <StackPanel>
                                    <CheckBox x:Name="ModeEnableBox"
                                              Content="Apply Device Mode"
                                              FontWeight="Bold"
                                              Margin="0,0,0,6" />

                                    <StackPanel Orientation="Horizontal"
                                                Margin="20,0,0,0"
                                                IsEnabled="{Binding ElementName=ModeEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="ModeTransmitterRadio"
                                                     GroupName="ModeRadios"
                                                     Content="Transmitter"
                                                     IsChecked="True"
                                                     Margin="0,0,16,0" />
                                        <RadioButton x:Name="ModeReceiverRadio"
                                                     GroupName="ModeRadios"
                                                     Content="Receiver" />
                                    </StackPanel>

                                    <TextBlock Text="Only applies to DM-NVX units that expose DeviceSpecific.DeviceMode."
                                               FontSize="11"
                                               Foreground="#666"
                                               TextWrapping="Wrap"
                                               Margin="20,6,0,0" />
                                </StackPanel>
                            </GroupBox>

                            <!-- AV Settings -->
                            <GroupBox Header="AV Settings" Margin="0,0,0,8" Padding="8">
                                <StackPanel>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*" />
                                            <ColumnDefinition Width="*" />
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto" />
                                            <RowDefinition Height="Auto" />
                                            <RowDefinition Height="Auto" />
                                        </Grid.RowDefinitions>

                                        <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,16,8">
                                            <CheckBox x:Name="AvInputHdcpEnableBox"
                                                      Content="Apply Input HDCP"
                                                      FontWeight="Bold" />
                                            <ComboBox x:Name="AvInputHdcpModeBox"
                                                      Margin="20,8,0,0"
                                                      Width="180"
                                                      HorizontalAlignment="Left"
                                                      Padding="4,2"
                                                      IsEnabled="{Binding ElementName=AvInputHdcpEnableBox, Path=IsChecked}" />
                                        </StackPanel>

                                        <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,8">
                                            <CheckBox x:Name="AvOutputHdcpEnableBox"
                                                      Content="Apply Output HDCP"
                                                      FontWeight="Bold" />
                                            <ComboBox x:Name="AvOutputHdcpModeBox"
                                                      Margin="20,8,0,0"
                                                      Width="180"
                                                      HorizontalAlignment="Left"
                                                      Padding="4,2"
                                                      IsEnabled="{Binding ElementName=AvOutputHdcpEnableBox, Path=IsChecked}" />
                                        </StackPanel>

                                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,16,8">
                                            <CheckBox x:Name="AvOutputResolutionEnableBox"
                                                      Content="Apply Output Resolution"
                                                      FontWeight="Bold" />
                                            <ComboBox x:Name="AvOutputResolutionBox"
                                                      Margin="20,8,0,0"
                                                      Width="180"
                                                      HorizontalAlignment="Left"
                                                      Padding="4,2"
                                                      IsEnabled="{Binding ElementName=AvOutputResolutionEnableBox, Path=IsChecked}" />
                                        </StackPanel>

                                        <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2">
                                            <CheckBox x:Name="AvGlobalEdidEnableBox"
                                                      Content="Apply Global EDID"
                                                      FontWeight="Bold" />
                                            <Grid Margin="20,8,0,0"
                                                  IsEnabled="{Binding ElementName=AvGlobalEdidEnableBox, Path=IsChecked}">
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="Auto" />
                                                    <ColumnDefinition Width="280" />
                                                    <ColumnDefinition Width="Auto" />
                                                    <ColumnDefinition Width="140" />
                                                    <ColumnDefinition Width="*" />
                                                </Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Text="Name" Margin="0,0,8,0" VerticalAlignment="Center" />
                                                <ComboBox x:Name="AvGlobalEdidNameBox"
                                                          Grid.Column="1"
                                                          Padding="4,2"
                                                          IsEditable="True"
                                                          Text="4K60 444 2CH Non-HDR" />
                                                <TextBlock Grid.Column="2" Text="Type" Margin="16,0,8,0" VerticalAlignment="Center" />
                                                <ComboBox x:Name="AvGlobalEdidTypeBox" Grid.Column="3" Padding="4,2" />
                                            </Grid>
                                        </StackPanel>
                                    </Grid>

                                    <TextBlock Text="Global EDID is skipped on older AudioVideoInputOutput firmware below 2.5.0."
                                               FontSize="11"
                                               Foreground="#666"
                                               TextWrapping="Wrap"
                                               Margin="20,6,0,0" />
                                </StackPanel>
                            </GroupBox>
                        </StackPanel>
                    </ScrollViewer>

                </DockPanel>
            </TabItem>
            <TabItem Header="Per-Device" x:Name="PerDeviceTab">
                <DockPanel Margin="8">
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="PerDeviceApplyButton"   Grid.Column="0" Content="Apply Changes"       Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="PerDeviceAddButton"     Grid.Column="1" Content="Add Devices..."      Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="PerDeviceRefreshButton" Grid.Column="2" Content="Fetch current state" Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="PerDeviceRebootButton"  Grid.Column="3" Content="Reboot Selected"     Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="PerDeviceClearButton"   Grid.Column="4" Content="Clear Loaded"        Padding="10,4" Margin="8,0,0,0" />
                        <TextBlock x:Name="PerDeviceProgressText" Grid.Column="5" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#CC0000" FontWeight="Bold" />
                        <Button x:Name="PerDeviceCancelButton"  Grid.Column="6" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <TextBlock DockPanel.Dock="Top" Margin="0,0,0,6" TextWrapping="Wrap" Foreground="#666" FontSize="11"
                               Text="Edit per-device values inline. IP changes are fire-and-forget — Success means the device acknowledged the change before its current TCP connection dropped, not that the new IP is reachable. Use the Verify tab afterwards to confirm." />

                    <Grid DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <TextBlock x:Name="PerDeviceSummaryText" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                    </Grid>

                    <ScrollViewer VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled">
                    <StackPanel>
                    <GroupBox Header="Device Settings" Padding="8" Margin="0,0,0,8">
                    <ScrollViewer HorizontalScrollBarVisibility="Visible"
                                  VerticalScrollBarVisibility="Disabled">
                    <DataGrid x:Name="PerDeviceGrid"
                              Width="1580"
                              HorizontalAlignment="Left"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridTextColumn      Header="IP"          Binding="{Binding IP}"          Width="120" IsReadOnly="True" />
                            <DataGridTextColumn      Header="Model"       Binding="{Binding Model}"       Width="90"  IsReadOnly="True" />
                            <DataGridTemplateColumn Header="Hostname" Width="170">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewHostname}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding NewHostname, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="TX/RX Mode" Width="115">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding DeviceMode}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox SelectedItem="{Binding DeviceMode, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                IsEnabled="{Binding SupportsModeChange}">
                                            <ComboBox.Items>
                                                <sys:String>N/A</sys:String>
                                                <sys:String>Transmitter</sys:String>
                                                <sys:String>Receiver</sys:String>
                                            </ComboBox.Items>
                                        </ComboBox>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="IP Mode" Width="95">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding IPMode}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox SelectedItem="{Binding IPMode, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                  IsEnabled="{Binding SupportsNetwork}">
                                            <ComboBox.Items>
                                                <sys:String>N/A</sys:String>
                                                <sys:String>Keep</sys:String>
                                                <sys:String>DHCP</sys:String>
                                                <sys:String>Static</sys:String>
                                            </ComboBox.Items>
                                        </ComboBox>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="IP Address" Width="120">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewIP}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding NewIP, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="SubnetMask" Width="120">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding SubnetMask}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding SubnetMask, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="Gateway" Width="120">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding Gateway}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding Gateway, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="DNS1" Width="100">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding PrimaryDns}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding PrimaryDns, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="DNS2" Width="100">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding SecondaryDns}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding SecondaryDns, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsNetwork}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="WiFi Off" Width="70">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding DisableWifi, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                IsEnabled="{Binding HasWifi}"
                                                HorizontalAlignment="Center" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding DisableWifi, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                IsEnabled="{Binding HasWifi}"
                                                HorizontalAlignment="Center" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="IPID" Width="60">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewIpId}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding NewIpId, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsIpTable}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="CS IP" Width="130">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewControlSystemAddr}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding NewControlSystemAddr, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsIpTable}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridCheckBoxColumn  Header="Reboot?"     Binding="{Binding NeedsReboot, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="70" />
                            <DataGridTextColumn      Header="Detail"      Binding="{Binding Detail}"     Width="*"   IsReadOnly="True" />
                        </DataGrid.Columns>
                    </DataGrid>
                    </ScrollViewer>
                    </GroupBox>

                    <GroupBox Header="AV Inputs" Padding="8" Margin="0,0,0,8">
                    <ScrollViewer HorizontalScrollBarVisibility="Visible"
                                  VerticalScrollBarVisibility="Disabled">
                    <DataGrid x:Name="PerDeviceAvInputGrid"
                              Width="980"
                              HorizontalAlignment="Left"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="IP"       Binding="{Binding IP}"        Width="120" IsReadOnly="True" />
                            <DataGridTextColumn Header="Input"    Binding="{Binding InputLabel}" Width="150" IsReadOnly="True" />
                            <DataGridTextColumn Header="Port"     Binding="{Binding PortType}"  Width="90"  IsReadOnly="True" />
                            <DataGridTextColumn Header="Cur EDID" Binding="{Binding CurrentEdid}" Width="190" IsReadOnly="True" />
                            <DataGridTemplateColumn Header="EDID" Width="200">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewEdidName}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox Text="{Binding NewEdidName, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                  ItemsSource="{Binding EdidNameOptions}"
                                                  IsEditable="True"
                                                  IsTextSearchEnabled="True"
                                                  IsEnabled="{Binding SupportsEdidEdit}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="Cur HDCP" Binding="{Binding CurrentInputHdcp}" Width="110" IsReadOnly="True" />
                            <DataGridTemplateColumn Header="Input HDCP" Width="125">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewInputHdcp}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox SelectedItem="{Binding NewInputHdcp, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                  IsEnabled="{Binding SupportsAvSettings}">
                                            <ComboBox.Items>
                                                <sys:String>N/A</sys:String>
                                                <sys:String>Auto</sys:String>
                                                <sys:String>HDCP 1.4</sys:String>
                                                <sys:String>HDCP 2.x</sys:String>
                                                <sys:String>Never Authenticate</sys:String>
                                            </ComboBox.Items>
                                        </ComboBox>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                    </ScrollViewer>
                    </GroupBox>

                    <GroupBox Header="AV Outputs" Padding="8" Margin="0,0,0,8">
                    <ScrollViewer HorizontalScrollBarVisibility="Visible"
                                  VerticalScrollBarVisibility="Disabled">
                    <DataGrid x:Name="PerDeviceAvOutputGrid"
                              Width="830"
                              HorizontalAlignment="Left"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="IP"        Binding="{Binding IP}"          Width="120" IsReadOnly="True" />
                            <DataGridTextColumn Header="Output"    Binding="{Binding OutputLabel}" Width="150" IsReadOnly="True" />
                            <DataGridTextColumn Header="Cur HDCP"  Binding="{Binding CurrentOutputHdcp}" Width="120" IsReadOnly="True" />
                            <DataGridTemplateColumn Header="Output HDCP" Width="135">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewOutputHdcp}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox SelectedItem="{Binding NewOutputHdcp, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                  IsEnabled="{Binding SupportsAvSettings}">
                                            <ComboBox.Items>
                                                <sys:String>N/A</sys:String>
                                                <sys:String>Auto</sys:String>
                                                <sys:String>FollowInput</sys:String>
                                                <sys:String>ForceHighest</sys:String>
                                                <sys:String>NeverAuthenticate</sys:String>
                                            </ComboBox.Items>
                                        </ComboBox>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="Cur Resolution" Binding="{Binding CurrentOutputResolution}" Width="130" IsReadOnly="True" />
                            <DataGridTemplateColumn Header="Output Resolution" Width="150">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewOutputResolution}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <ComboBox SelectedItem="{Binding NewOutputResolution, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                  IsEnabled="{Binding SupportsAvSettings}">
                                            <ComboBox.Items>
                                                <sys:String>N/A</sys:String>
                                                <sys:String>Auto</sys:String>
                                                <sys:String>1920x1080@60</sys:String>
                                                <sys:String>3840x2160@30</sys:String>
                                                <sys:String>3840x2160@60</sys:String>
                                            </ComboBox.Items>
                                        </ComboBox>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                    </ScrollViewer>
                    </GroupBox>

                    <GroupBox Header="Multicast" Padding="8">
                    <ScrollViewer HorizontalScrollBarVisibility="Visible"
                                  VerticalScrollBarVisibility="Disabled">
                    <DataGrid x:Name="PerDeviceMulticastGrid"
                              Width="560"
                              HorizontalAlignment="Left"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="IP"         Binding="{Binding IP}"        Width="120" IsReadOnly="True" />
                            <DataGridTextColumn Header="Direction"  Binding="{Binding Direction}" Width="100" IsReadOnly="True" />
                            <DataGridTextColumn Header="Current MC" Binding="{Binding CurrentMulticastAddress}" Width="150" IsReadOnly="True" />
                            <DataGridTemplateColumn Header="MC Address" Width="150">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding NewMulticastAddress}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                                <DataGridTemplateColumn.CellEditingTemplate>
                                    <DataTemplate>
                                        <TextBox Text="{Binding NewMulticastAddress, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                                 IsEnabled="{Binding SupportsAvMulticast}" />
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellEditingTemplate>
                            </DataGridTemplateColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                    </ScrollViewer>
                    </GroupBox>

                    </StackPanel>
                    </ScrollViewer>

                </DockPanel>
            </TabItem>
            <TabItem Header="Verify" x:Name="VerifyTab">
                <DockPanel Margin="8">

                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="VerifyStartButton"  Grid.Column="0" Content="Verify Selected" Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="VerifyReloadButton" Grid.Column="1" Content="Reload from provisioning CSV" Padding="10,4" Margin="8,0,0,0" />
                        <TextBlock x:Name="VerifyProgressText" Grid.Column="2" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#666" />
                        <Button x:Name="VerifyCancelButton" Grid.Column="3" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <Grid DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="VerifySummaryText" Grid.Column="0" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                        <CheckBox  x:Name="VerifySelectAll" Grid.Column="1" Content="Select all" IsChecked="True" />
                    </Grid>

                    <DataGrid x:Name="VerifyGrid"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              HorizontalScrollBarVisibility="Visible"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="Sel" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40" />
                            <DataGridTextColumn Header="IP"        Binding="{Binding IP}"        Width="140" IsReadOnly="True" />
                            <DataGridTextColumn Header="Verified"  Binding="{Binding Verified}"  Width="90"  IsReadOnly="True" />
                            <DataGridTextColumn Header="State"     Binding="{Binding State}"     Width="160" IsReadOnly="True" />
                            <DataGridTextColumn Header="Detail"    Binding="{Binding Detail}"    Width="*"   IsReadOnly="True" />
                            <DataGridTextColumn Header="Checked"   Binding="{Binding CheckedAt}" Width="160" IsReadOnly="True" />
                        </DataGrid.Columns>
                    </DataGrid>

                </DockPanel>
            </TabItem>
            <TabItem Header="Settings" x:Name="SettingsTab">
                <DockPanel Margin="12">
                    <StackPanel DockPanel.Dock="Top" MaxWidth="520" HorizontalAlignment="Left">
                        <TextBlock Text="GUI Settings" FontSize="18" FontWeight="Bold" Margin="0,0,0,8" />
                        <TextBlock Text="These settings are saved locally in the workspace and are not pushed to devices." Foreground="#666" TextWrapping="Wrap" Margin="0,0,0,12" />

                        <GroupBox Header="Default Credentials" Padding="10" Margin="0,0,0,12">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="140" />
                                    <ColumnDefinition Width="*" />
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                    <RowDefinition Height="Auto" />
                                </Grid.RowDefinitions>

                                <TextBlock Grid.Row="0" Grid.Column="0" Text="Username" VerticalAlignment="Center" Margin="0,0,8,8" />
                                <TextBox x:Name="SettingsDefaultUsernameBox" Grid.Row="0" Grid.Column="1" Padding="4,2" Margin="0,0,0,8" />

                                <TextBlock Grid.Row="1" Grid.Column="0" Text="Password" VerticalAlignment="Center" Margin="0,0,8,8" />
                                <PasswordBox x:Name="SettingsDefaultPasswordBox" Grid.Row="1" Grid.Column="1" Padding="4,2" Margin="0,0,0,8" />

                                <TextBlock Grid.Row="2" Grid.Column="1"
                                        Text="Password is encrypted using the current Windows user account."
                                        Foreground="#888"
                                        FontSize="11"
                                        TextWrapping="Wrap" />
                            </Grid>
                        </GroupBox>

                        <GroupBox Header="Most Used Subnets" Padding="10" Margin="0,0,0,12">
                            <StackPanel>
                                <TextBlock Text="Enter one CIDR per line. These will populate the Scan tab and Add Devices CIDR scan by default."
                                        Foreground="#666"
                                        FontSize="11"
                                        TextWrapping="Wrap"
                                        Margin="0,0,0,6" />

                                <TextBox x:Name="SettingsMostUsedSubnetsBox"
                                        Height="90"
                                        AcceptsReturn="True"
                                        TextWrapping="NoWrap"
                                        VerticalScrollBarVisibility="Auto"
                                        HorizontalScrollBarVisibility="Auto"
                                        FontFamily="Consolas"
                                        Padding="4,2" />
                            </StackPanel>
                        </GroupBox>

                        <GroupBox Header="Appearance" Padding="10" Margin="0,0,0,12">
                            <CheckBox x:Name="SettingsDarkModeBox"
                            Content="Enable dark mode (coming soon)"
                            IsEnabled="False" />
                        </GroupBox>

                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="SettingsSaveButton" Content="Save Settings" Padding="14,4" FontWeight="Bold" />
                            <Button x:Name="SettingsClearPasswordButton" Content="Clear Saved Password" Padding="14,4" Margin="8,0,0,0" />
                            <TextBlock x:Name="SettingsStatusText" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#666" />
                        </StackPanel>
                    </StackPanel>
                </DockPanel>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@

# ---- Parse and locate named elements -----------------------------------------
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$Script:UI = @{}
foreach ($name in 'StatusText','WorkspaceText','CredText','ForgetCredButton','MainTabs',
                  'ScanCidrInput','ScanAddCidr','ScanRemoveCidr','ScanCidrList',
                  'ScanStartButton','ScanCancelButton','ScanProgressText',
                  'ScanResultsGrid','ScanSelectAll','ScanSummaryText',
                  'SettingsMostUsedSubnetsBox','SettingsDefaultUsernameBox','SettingsDefaultPasswordBox','SettingsDarkModeBox','SettingsSaveButton','SettingsClearPasswordButton','SettingsStatusText',
                  'ProvisionTab','ProvisionStartButton','ProvisionReloadButton',
                  'ProvisionCancelButton','ProvisionProgressText',
                  'ProvisionGrid','ProvisionSelectAll','ProvisionSummaryText',
                  'VerifyTab','VerifyStartButton','VerifyReloadButton',
                  'VerifyCancelButton','VerifyProgressText',
                  'VerifyGrid','VerifySelectAll','VerifySummaryText',
                  'BlanketTab','BlanketGrid','BlanketSelectAll','BlanketSummaryText',
                  'BlanketReloadButton','BlanketApplyButton','BlanketClearButton','BlanketCancelButton','BlanketCapabilityButton','BlanketProgressText',
                  'NtpEnableBox','NtpServerBox','NtpTimeZoneBox',
                  'CloudEnableBox','CloudOnRadio','CloudOffRadio',
                  'FusionEnableBox','FusionOnRadio','FusionOffRadio',
                  'AutoUpdateEnableBox','AutoUpdateOnRadio','AutoUpdateOffRadio',
                  'ModeEnableBox','ModeTransmitterRadio','ModeReceiverRadio',
                  'AvInputHdcpEnableBox','AvInputHdcpModeBox',
                  'AvOutputHdcpEnableBox','AvOutputHdcpModeBox',
                  'AvOutputResolutionEnableBox','AvOutputResolutionBox',
                  'AvGlobalEdidEnableBox','AvGlobalEdidNameBox','AvGlobalEdidTypeBox',
                  'PerDeviceTab','PerDeviceGrid','PerDeviceAvInputGrid','PerDeviceAvOutputGrid','PerDeviceMulticastGrid','PerDeviceSummaryText',
                  'PerDeviceApplyButton','PerDeviceRefreshButton','PerDeviceAddButton','PerDeviceClearButton',
                  'PerDeviceCancelButton','PerDeviceProgressText',
                  'ProvisionRebootButton','BlanketRebootButton','PerDeviceRebootButton',
                  'WorkflowTab','WorkflowStartButton','WorkflowContinueButton','WorkflowCancelButton',
                  'WorkflowStatusText','WorkflowStepsList',
                  'WorkflowRebootPanel','WorkflowCountdownText','WorkflowOnlineText','WorkflowRebootGrid') {
    $Script:UI[$name] = $window.FindName($name)
}

function Initialize-SettingsTab {
    if (-not $Script:GuiSettings) {
        $Script:GuiSettings = New-DefaultGuiSettings
    }

    $Script:UI.SettingsDefaultUsernameBox.Text = "$($Script:GuiSettings.DefaultUsername)"
    $Script:UI.SettingsDefaultPasswordBox.Password = Unprotect-GuiSettingPassword $Script:GuiSettings.ProtectedDefaultPassword
    $Script:UI.SettingsMostUsedSubnetsBox.Text = (($Script:GuiSettings.MostUsedSubnets | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }) -join "`r`n")
    $Script:UI.SettingsDarkModeBox.IsChecked = $false
    $Script:UI.SettingsStatusText.Text = ''
}

function Find-VisualChildren {
    param(
        [System.Windows.DependencyObject]$Parent,
        [type]$ChildType
    )

    if (-not $Parent) { return }

    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent)

    for ($i = 0; $i -lt $count; $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)

        if ($child -and $ChildType.IsAssignableFrom($child.GetType())) {
            $child
        }

        Find-VisualChildren -Parent $child -ChildType $ChildType
    }
}

function New-Brush {
    param(
        [Parameter(Mandatory)][string]$Color
    )

    return [System.Windows.Media.SolidColorBrush](
        [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    )
}

function Apply-GuiTheme {
    param(
        [bool]$DarkMode
    )

    if (-not $window) { return }

    if ($DarkMode) {
        $bg          = New-Brush '#1E1E1E'
        $panelBg     = New-Brush '#252526'
        $controlBg   = New-Brush '#2D2D30'
        $textFg      = New-Brush '#E6E6E6'
        $borderBrush = New-Brush '#555555'
        $gridAltBg   = New-Brush '#333337'
        $buttonBg    = New-Brush '#3A3A3D'
        $statusBg    = New-Brush '#111111'
    }
    else {
        $bg          = New-Brush '#FFFFFF'
        $panelBg     = New-Brush '#FFFFFF'
        $controlBg   = New-Brush '#FFFFFF'
        $textFg      = New-Brush '#000000'
        $borderBrush = New-Brush '#DDDDDD'
        $gridAltBg   = New-Brush '#F8F8F8'
        $buttonBg    = New-Brush '#F0F0F0'
        $statusBg    = New-Brush '#F0F0F0'
    }

    $window.Background = $bg
    $window.Foreground = $textFg

    foreach ($border in Find-VisualChildren $window ([System.Windows.Controls.Border])) {
        $border.Background = $panelBg
        $border.BorderBrush = $borderBrush
    }

    foreach ($group in Find-VisualChildren $window ([System.Windows.Controls.GroupBox])) {
        $group.Background = $panelBg
        $group.Foreground = $textFg
        $group.BorderBrush = $borderBrush
    }

    foreach ($tab in Find-VisualChildren $window ([System.Windows.Controls.TabControl])) {
        $tab.Background = $bg
        $tab.Foreground = $textFg
        $tab.BorderBrush = $borderBrush
    }

    foreach ($tabItem in Find-VisualChildren $window ([System.Windows.Controls.TabItem])) {
        $tabItem.Background = if ($DarkMode) { $controlBg } else { $buttonBg }
        $tabItem.Foreground = $textFg
        $tabItem.BorderBrush = $borderBrush
    }

    foreach ($tb in Find-VisualChildren $window ([System.Windows.Controls.TextBlock])) {
        $tb.Foreground = $textFg
    }

    foreach ($box in Find-VisualChildren $window ([System.Windows.Controls.TextBox])) {
        $box.Background = $controlBg
        $box.Foreground = $textFg
        $box.BorderBrush = $borderBrush
        $box.CaretBrush = $textFg
    }

    foreach ($box in Find-VisualChildren $window ([System.Windows.Controls.PasswordBox])) {
        $box.Background = $controlBg
        $box.Foreground = $textFg
        $box.BorderBrush = $borderBrush
        $box.CaretBrush = $textFg
    }

    foreach ($combo in Find-VisualChildren $window ([System.Windows.Controls.ComboBox])) {
        $combo.Background = $controlBg
        $combo.Foreground = $textFg
        $combo.BorderBrush = $borderBrush
    }

    foreach ($button in Find-VisualChildren $window ([System.Windows.Controls.Button])) {
        $button.Background = $buttonBg
        $button.Foreground = $textFg
        $button.BorderBrush = $borderBrush
    }

    foreach ($check in Find-VisualChildren $window ([System.Windows.Controls.CheckBox])) {
        $check.Foreground = $textFg
    }

    foreach ($radio in Find-VisualChildren $window ([System.Windows.Controls.RadioButton])) {
        $radio.Foreground = $textFg
    }

    foreach ($grid in Find-VisualChildren $window ([System.Windows.Controls.DataGrid])) {
        $grid.Background = $panelBg
        $grid.Foreground = $textFg
        $grid.RowBackground = $panelBg
        $grid.AlternatingRowBackground = $gridAltBg
        $grid.HorizontalGridLinesBrush = $borderBrush
        $grid.VerticalGridLinesBrush = $borderBrush
        $grid.BorderBrush = $borderBrush

        # Avoid clipping/odd header rendering after theme changes.
        $grid.HeadersVisibility = 'Column'
        $grid.ColumnHeaderHeight = 24
    }

    foreach ($status in Find-VisualChildren $window ([System.Windows.Controls.Primitives.StatusBar])) {
        $status.Background = $statusBg
        $status.Foreground = $textFg
    }
}

# ---- Helpers -----------------------------------------------------------------
function Update-Status ($text) {
    $Script:UI.StatusText.Text = $text
}

function Update-CredentialDisplay {
    if ($null -eq $Script:AppState.Credential) {
        $Script:UI.CredText.Text       = 'not entered'
        $Script:UI.CredText.Foreground = '#888'
    } else {
        $Script:UI.CredText.Text       = $Script:AppState.Credential.UserName
        $Script:UI.CredText.Foreground = '#1A7F37'
    }
}

function Get-CachedCredential {
    param(
        [switch]$OfferSavedDefault
    )

    if ($null -ne $Script:AppState.Credential) {
        return $Script:AppState.Credential
    }

    $hasSavedDefault = $Script:GuiSettings -and
                       -not [string]::IsNullOrWhiteSpace($Script:GuiSettings.DefaultUsername) -and
                       -not [string]::IsNullOrWhiteSpace($Script:GuiSettings.ProtectedDefaultPassword)

    if ($OfferSavedDefault -and $hasSavedDefault) {
        $answer = [System.Windows.MessageBox]::Show(
            "Use saved default credentials from Settings for this provisioning step?`n`nUsername: $($Script:GuiSettings.DefaultUsername)",
            "Use default credentials?",
            'YesNoCancel',
            'Question'
        )

        if ($answer -eq 'Cancel') {
            return $null
        }

        if ($answer -eq 'Yes') {
            $plainPassword = Unprotect-GuiSettingPassword $Script:GuiSettings.ProtectedDefaultPassword

            if (-not [string]::IsNullOrWhiteSpace($plainPassword)) {
                try {
                    $secure = ConvertTo-SecureString $plainPassword -AsPlainText -Force
                    $cred = [pscredential]::new($Script:GuiSettings.DefaultUsername, $secure)

                    $Script:AppState.Credential = $cred
                    Update-CredentialDisplay
                    return $cred
                }
                catch {
                    [System.Windows.MessageBox]::Show(
                        "Saved default password could not be decrypted. The normal credential dialog will be shown.",
                        "Saved credential error",
                        'OK',
                        'Warning'
                    ) | Out-Null
                }
            }
        }
    }

    $cred = Show-CredentialDialog

    if ($cred -and $cred.UserName -and $cred.GetNetworkCredential().Password) {
        $Script:AppState.Credential = $cred
        Update-CredentialDisplay
        return $cred
    }

    return $null
}

function Show-CredentialDialog {
    # Minimal WPF fallback used when $Host.UI.PromptForCredential is unavailable.
    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Crestron Admin Credentials"
        Width="360" Height="200"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Username" Margin="0,0,0,2" />
        <TextBox x:Name="UserBox" Grid.Row="1" Padding="4,2" />
        <TextBlock Grid.Row="2" Text="Password" Margin="0,8,0,2" />
        <PasswordBox x:Name="PassBox" Grid.Row="3" Padding="4,2" />
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="CancelBtn" Content="Cancel" Padding="14,4" Margin="0,0,8,0" />
            <Button x:Name="OkBtn" Content="OK" Padding="14,4" IsDefault="True" />
        </StackPanel>
    </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($dxaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)

    $userBox = $dlg.FindName('UserBox')
    $passBox = $dlg.FindName('PassBox')
    $okBtn   = $dlg.FindName('OkBtn')
    $cancel  = $dlg.FindName('CancelBtn')

    if ($Script:GuiSettings) {
        if (-not [string]::IsNullOrWhiteSpace($Script:GuiSettings.DefaultUsername)) {
            $userBox.Text = "$($Script:GuiSettings.DefaultUsername)"
        }

        if (-not [string]::IsNullOrWhiteSpace($Script:GuiSettings.ProtectedDefaultPassword)) {
            $defaultPassword = Unprotect-GuiSettingPassword $Script:GuiSettings.ProtectedDefaultPassword

            if (-not [string]::IsNullOrWhiteSpace($defaultPassword)) {
                $passBox.Password = $defaultPassword
            }
        }
    }

    $script:_credResult = $null

    $okBtn.Add_Click({
        if ($userBox.Text -and $passBox.Password) {
            $sec = ConvertTo-SecureString $passBox.Password -AsPlainText -Force
            $script:_credResult = [pscredential]::new($userBox.Text, $sec)
            $dlg.DialogResult = $true
            $dlg.Close()
        }
    })

    $cancel.Add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $dlg.Owner = $window

    if ($userBox.Text -and -not $passBox.Password) {
        $passBox.Focus() | Out-Null
    } else {
        $userBox.Focus() | Out-Null
    }

    [void]$dlg.ShowDialog()

    return $script:_credResult
}

function Open-Workspace {
    Start-Process explorer.exe $Script:AppState.WorkspaceDirectory
}

# ---- Wire up event handlers --------------------------------------------------
$Script:UI.WorkspaceText.Text = $Script:AppState.WorkspaceDirectory
$Script:UI.WorkspaceText.Add_MouseLeftButtonUp({ Open-Workspace })

$Script:UI.ForgetCredButton.Add_Click({
    $Script:AppState.Credential = $null
    Update-CredentialDisplay
    Update-Status 'Credentials cleared.'
})

Update-CredentialDisplay
Update-Status 'Ready.'

if ($Script:UI.BlanketRebootButton) {
    $Script:UI.BlanketRebootButton.IsEnabled = $false
}

if ($Script:UI.PerDeviceRebootButton) {
    $Script:UI.PerDeviceRebootButton.IsEnabled = $false
}

# =============================================================================
# Scan tab
# =============================================================================

# CIDR list — backing ObservableCollection so the ListBox auto-updates
$Script:ScanState = [pscustomobject]@{
    Cidrs        = [System.Collections.ObjectModel.ObservableCollection[string]]::new()
    Results      = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    Runspace     = $null
    PowerShell   = $null
    AsyncHandle  = $null
    Timer        = $null
    IsScanning   = $false
}
# ScanCidrList is now a StackPanel of CheckBox controls, populated by Initialize-ScanCidrs.
$Script:UI.ScanResultsGrid.ItemsSource = $Script:ScanState.Results

function Add-ScanCidrCheckbox {
    param(
        [Parameter(Mandatory)][string]$Cidr,
        [bool]$Checked = $true
    )

    if (-not $Script:UI.ScanCidrList) {
        return
    }

    foreach ($child in $Script:UI.ScanCidrList.Children) {
        if ("$($child.Content)" -eq $Cidr) {
            $child.IsChecked = $Checked
            return
        }
    }

    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = $Cidr
    $check.IsChecked = $Checked
    $check.Margin = '2,2,2,2'

    [void]$Script:UI.ScanCidrList.Children.Add($check)
}

function Get-CheckedScanCidrs {
    $cidrs = @()

    if (-not $Script:UI.ScanCidrList) {
        return $cidrs
    }

    foreach ($child in $Script:UI.ScanCidrList.Children) {
        if ([bool]$child.IsChecked) {
            $cidrs += "$($child.Content)"
        }
    }

    return @($cidrs | Sort-Object -Unique)
}

function Sync-ScanStateFromCheckedCidrs {
    $Script:ScanState.Cidrs.Clear()

    foreach ($cidr in Get-CheckedScanCidrs) {
        [void]$Script:ScanState.Cidrs.Add($cidr)
    }
}

# Seed CIDRs: load from existing subnets.txt or pre-fill 172.22.0.0/24
function Initialize-ScanCidrs {
    $Script:ScanState.Cidrs.Clear()

    if ($Script:UI.ScanCidrList) {
        $Script:UI.ScanCidrList.Children.Clear()
    }

    $settingsSubnets = @()

    if ($Script:GuiSettings -and
        $Script:GuiSettings.PSObject.Properties.Name -contains 'MostUsedSubnets' -and
        $Script:GuiSettings.MostUsedSubnets) {

        $settingsSubnets = @($Script:GuiSettings.MostUsedSubnets | Where-Object {
            $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
        })
    }

    if ($settingsSubnets.Count -eq 0 -and (Test-Path $Script:AppState.SubnetsFile)) {
        $settingsSubnets = @(Get-Content $Script:AppState.SubnetsFile |
            ForEach-Object { ($_ -split '#')[0].Trim() } |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' })
    }

    if ($settingsSubnets.Count -eq 0) {
        $settingsSubnets = @('192.168.20.0/24')
    }

    foreach ($cidr in ($settingsSubnets | Sort-Object -Unique)) {
        Add-ScanCidrCheckbox -Cidr $cidr -Checked $true
        [void]$Script:ScanState.Cidrs.Add($cidr)
    }

    Save-ScanCidrs
}

function Save-ScanCidrs {
    $Script:ScanState.Cidrs | Set-Content -Path $Script:AppState.SubnetsFile -Encoding UTF8
}

function Add-ScanCidr {
    $entry = $Script:UI.ScanCidrInput.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($entry)) {
        return
    }

    if ($entry -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
        [System.Windows.MessageBox]::Show(
            "Invalid CIDR. Example: 192.168.20.0/24",
            "Invalid input",
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    Add-ScanCidrCheckbox -Cidr $entry -Checked $true
    Sync-ScanStateFromCheckedCidrs
    Save-ScanCidrs

    $Script:UI.ScanCidrInput.Clear()
}

function Remove-ScanCidr {
    if (-not $Script:UI.ScanCidrList) {
        return
    }

    $toRemove = @()

    foreach ($child in $Script:UI.ScanCidrList.Children) {
        if ([bool]$child.IsChecked) {
            $toRemove += $child
        }
    }

    if ($toRemove.Count -eq 0) {
        Update-Status 'No checked subnets to remove.'
        return
    }

    foreach ($child in $toRemove) {
        $Script:UI.ScanCidrList.Children.Remove($child)
    }

    Sync-ScanStateFromCheckedCidrs
    Save-ScanCidrs
}

function Set-ScanControls ($isScanning) {
    $Script:ScanState.IsScanning             = $isScanning
    $Script:UI.ScanStartButton.IsEnabled     = -not $isScanning
    $Script:UI.ScanCancelButton.IsEnabled    = $isScanning
    $Script:UI.ScanAddCidr.IsEnabled         = -not $isScanning
    $Script:UI.ScanRemoveCidr.IsEnabled      = -not $isScanning
    $Script:UI.ScanCidrInput.IsEnabled       = -not $isScanning
    $Script:UI.ScanCidrList.IsEnabled        = -not $isScanning
}

function Update-ScanSummary {
    $count    = $Script:ScanState.Results.Count
    $selected = ($Script:ScanState.Results | Where-Object Selected).Count
    $Script:UI.ScanSummaryText.Text = "Found $count device(s). Selected: $selected"
}

function Save-ScanCsv {
    if ($Script:ScanState.Results.Count -eq 0) { return }
    # Only persist the canonical columns expected by the Provision tab + downstream
    $Script:ScanState.Results | Select-Object IP, @{N='BootupPage';E={$true}}, MatchedSig, ScannedAt |
        Export-Csv -NoTypeInformation -Path $Script:AppState.ScanCsv
}

function Stop-ScanTimer {
    if ($Script:ScanState.Timer) {
        $Script:ScanState.Timer.Stop()
        $Script:ScanState.Timer = $null
    }
}

function Stop-ScanRunspace {
    if ($Script:ScanState.PowerShell) {
        try { $Script:ScanState.PowerShell.Stop() } catch {}
        try { $Script:ScanState.PowerShell.Dispose() } catch {}
        $Script:ScanState.PowerShell  = $null
        $Script:ScanState.AsyncHandle = $null
    }
    if ($Script:ScanState.Runspace) {
        try { $Script:ScanState.Runspace.Close() } catch {}
        try { $Script:ScanState.Runspace.Dispose() } catch {}
        $Script:ScanState.Runspace = $null
    }
}

function Start-Scan {
    if ($Script:ScanState.IsScanning) { return }

    Sync-ScanStateFromCheckedCidrs

    if ($Script:ScanState.Cidrs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Add at least one CIDR to the list before scanning.", "Nothing to scan", 'OK', 'Warning') | Out-Null
        return
    }
    Save-ScanCidrs

    $Script:ScanState.Results.Clear()
    Update-ScanSummary
    $Script:UI.ScanProgressText.Text = 'Scan in Progress...'
    Set-ScanControls $true
    Update-Status 'Scan in progress...'

    # Background runspace runs Find-CrestronBootup; results are appended to a
    # thread-safe queue read by a DispatcherTimer on the UI thread.
    $Script:ScanQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $Script:ScanDone  = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',       $Script:ScanQueue)
    $rs.SessionStateProxy.SetVariable('doneRef',     $Script:ScanDone)
    $rs.SessionStateProxy.SetVariable('cidrs',       @($Script:ScanState.Cidrs))
    $rs.SessionStateProxy.SetVariable('subnetsFile', $Script:AppState.SubnetsFile)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            Import-Module CrestronAdminBootstrap -Force -ErrorAction Stop
            # Write CIDRs to subnets file (Find-CrestronBootup takes a file path)
            $cidrs | Set-Content -Path $subnetsFile -Encoding UTF8
            # Stream results into the queue
            Find-CrestronBootup -CidrFile $subnetsFile | ForEach-Object {
                $queue.Enqueue($_)
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally {
            $doneRef.Value = $true
        }
    })

    $Script:ScanState.Runspace    = $rs
    $Script:ScanState.PowerShell  = $ps
    $Script:ScanState.AsyncHandle = $ps.BeginInvoke()

    # UI-thread timer that drains the queue
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $item = $null
        while ($Script:ScanQueue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Scan failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }
            # Add a Selected property for the checkbox column
            $row = [pscustomobject]@{
                Selected   = $true
                IP         = $item.IP
                MatchedSig = $item.MatchedSig
                ScannedAt  = $item.ScannedAt
            }
            $Script:ScanState.Results.Add($row)
        }
        Update-ScanSummary

        if ($Script:ScanDone.Value -and $Script:ScanQueue.IsEmpty) {
            Stop-ScanTimer
            Stop-ScanRunspace
            Set-ScanControls $false
            $count = $Script:ScanState.Results.Count
            $Script:UI.ScanProgressText.Text = "Done. Found $count device(s)."
            Save-ScanCsv
            $Script:UI.ScanSelectAll.IsChecked = $true
            Update-Status "Scan complete. $count device(s) found. Saved $($Script:AppState.ScanCsv)"
        }
    })
    $timer.Start()
    $Script:ScanState.Timer = $timer
}

function Stop-Scan {
    if (-not $Script:ScanState.IsScanning) { return }
    Stop-ScanTimer
    Stop-ScanRunspace
    Set-ScanControls $false
    $Script:UI.ScanProgressText.Text = 'Cancelled.'
    Update-Status 'Scan cancelled.'
}

# Wire up Scan tab events
$Script:UI.ScanAddCidr.Add_Click({ Add-ScanCidr })
$Script:UI.ScanCidrInput.Add_KeyDown({ param($s,$e) if ($e.Key -eq 'Return') { Add-ScanCidr } })
$Script:UI.ScanRemoveCidr.Add_Click({ Remove-ScanCidr })
$Script:UI.ScanStartButton.Add_Click({ Start-Scan })
$Script:UI.ScanCancelButton.Add_Click({ Stop-Scan })

$Script:UI.ScanSelectAll.Add_Checked({
    foreach ($r in $Script:ScanState.Results) { $r.Selected = $true }
    $Script:UI.ScanResultsGrid.Items.Refresh()
    Update-ScanSummary
})
$Script:UI.ScanSelectAll.Add_Unchecked({
    foreach ($r in $Script:ScanState.Results) { $r.Selected = $false }
    $Script:UI.ScanResultsGrid.Items.Refresh()
    Update-ScanSummary
})

# Refresh summary when user toggles per-row checkboxes
$Script:UI.ScanResultsGrid.Add_CellEditEnding({ Update-ScanSummary })

# Make sure runspaces are cleaned up on window close
$window.Add_Closed({
    Stop-ScanTimer
    Stop-ScanRunspace
})

Initialize-ScanCidrs

# =============================================================================
# Provision tab
# =============================================================================

$Script:ProvisionState = [pscustomobject]@{
    Rows         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    RowsByIP     = @{}              # IP -> row object for fast lookup
    Runspace     = $null
    PowerShell   = $null
    AsyncHandle  = $null
    Timer        = $null
    Queue        = $null
    DoneRef      = $null
    IsRunning    = $false
}
$Script:UI.ProvisionGrid.ItemsSource = $Script:ProvisionState.Rows

function Update-ProvisionSummary {
    $count    = $Script:ProvisionState.Rows.Count
    $selected = ($Script:ProvisionState.Rows | Where-Object Selected).Count
    $success  = ($Script:ProvisionState.Rows | Where-Object { $_.Success -eq 'True' }).Count
    $fail     = ($Script:ProvisionState.Rows | Where-Object { $_.Status -and $_.Success -ne 'True' -and $_.Status -ne 'Pending' -and $_.Status -ne 'Working' }).Count
    $Script:UI.ProvisionSummaryText.Text = "Loaded $count device(s). Selected: $selected. Success: $success. Failed: $fail."
}

function Set-ProvisionControls ($isRunning) {
    $Script:ProvisionState.IsRunning            = $isRunning
    $Script:UI.ProvisionStartButton.IsEnabled   = -not $isRunning
    $Script:UI.ProvisionReloadButton.IsEnabled  = -not $isRunning
    $Script:UI.ProvisionCancelButton.IsEnabled  = $isRunning
}

function Load-ProvisionFromScan {
    # Prefer in-memory scan results; fall back to CSV.
    $Script:ProvisionState.Rows.Clear()
    $Script:ProvisionState.RowsByIP.Clear()

    $source = @()
    if ($Script:ScanState.Results.Count -gt 0) {
        $source = $Script:ScanState.Results | ForEach-Object {
            [pscustomobject]@{ IP = $_.IP; Selected = $_.Selected }
        }
    } elseif (Test-Path $Script:AppState.ScanCsv) {
        try {
            $source = Import-Csv $Script:AppState.ScanCsv | ForEach-Object {
                [pscustomobject]@{ IP = $_.IP; Selected = $true }
            }
        } catch {
            Update-Status "Could not read $($Script:AppState.ScanCsv): $($_.Exception.Message)"
            return
        }
    } else {
        Update-Status 'No scan results to load. Run a scan first.'
        Update-ProvisionSummary
        return
    }

    foreach ($s in $source) {
        $row = [pscustomobject]@{
            Selected  = [bool]$s.Selected
            IP        = $s.IP
            Status    = ''
            Success   = ''
            Response  = ''
            Timestamp = ''
        }
        $Script:ProvisionState.Rows.Add($row)
        $Script:ProvisionState.RowsByIP[$s.IP] = $row
    }
    Update-ProvisionSummary
    Update-Status "Loaded $($Script:ProvisionState.Rows.Count) device(s) into Provision tab."
}

function Save-ProvisionCsv {
    if ($Script:ProvisionState.Rows.Count -eq 0) { return }
    $Script:ProvisionState.Rows |
        Where-Object Status -ne '' |
        Select-Object IP, Status, Success, Response, Timestamp |
        Export-Csv -NoTypeInformation -Path $Script:AppState.ProvisionCsv
}

function Stop-ProvisionRunspace {
    if ($Script:ProvisionState.Timer) {
        $Script:ProvisionState.Timer.Stop()
        $Script:ProvisionState.Timer = $null
    }
    if ($Script:ProvisionState.PowerShell) {
        try { $Script:ProvisionState.PowerShell.Stop() } catch {}
        try { $Script:ProvisionState.PowerShell.Dispose() } catch {}
        $Script:ProvisionState.PowerShell  = $null
        $Script:ProvisionState.AsyncHandle = $null
    }
    if ($Script:ProvisionState.Runspace) {
        try { $Script:ProvisionState.Runspace.Close() } catch {}
        try { $Script:ProvisionState.Runspace.Dispose() } catch {}
        $Script:ProvisionState.Runspace = $null
    }
}

function Start-Provision {
    if ($Script:ProvisionState.IsRunning) { return }
    $selectedIPs = @($Script:ProvisionState.Rows | Where-Object Selected | Select-Object -ExpandProperty IP)
    if ($selectedIPs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No devices selected.", "Nothing to provision", 'OK', 'Warning') | Out-Null
        return
    }

    $cred = Get-CachedCredential -OfferSavedDefault
    if (-not $cred) {
        Update-Status 'Provision cancelled (no credentials).'
        return
    }

    $confirmMsg = "About to provision $($selectedIPs.Count) device(s) with admin username '$($cred.UserName)'.`n`nContinue?"
    $confirm = [System.Windows.MessageBox]::Show($confirmMsg, "Confirm provisioning", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { Update-Status 'Provision cancelled.'; return }

    # Mark selected rows as Pending
    foreach ($ip in $selectedIPs) {
        $row = $Script:ProvisionState.RowsByIP[$ip]
        if ($row) {
            $row.Status   = 'Pending'
            $row.Success  = ''
            $row.Response = ''
            $row.Timestamp = ''
        }
    }
    $Script:UI.ProvisionGrid.Items.Refresh()
    $Script:UI.ProvisionProgressText.Text = "Provisioning $($selectedIPs.Count) device(s)..."
    Set-ProvisionControls $true
    Update-Status "Provisioning $($selectedIPs.Count) device(s)..."

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',    $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',  $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',      $selectedIPs)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module CrestronAdminBootstrap -Force -ErrorAction Stop
            $sec     = ConvertTo-SecureString $userPass -AsPlainText -Force
            $credObj = [pscredential]::new($userName, $sec)

            # Mark each as Working when picked up; results come back from Set-CrestronAdmin
            # which runs its own ForEach-Object -Parallel inside.
            foreach ($ip in $ips) {
                $queue.Enqueue([pscustomobject]@{ __progress = $true; IP = $ip; Status = 'Working' })
            }

            $results = Set-CrestronAdmin -IP $ips -Credential $credObj -Force
            foreach ($r in @($results)) {
                $displayStatus = if ($r.Success) {
                    'OK'
                }
                elseif ($r.Status) {
                    'Error'
                }
                else {
                    'Error'
                }

                $queue.Enqueue([pscustomobject]@{
                    __result  = $true
                    IP        = $r.IP
                    Status    = $displayStatus
                    Success   = "$($r.Success)"
                    Response  = $r.Response
                    Timestamp = $r.Timestamp
                })
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally {
            $doneRef.Value = $true
        }
    })

    $Script:ProvisionState.Runspace    = $rs
    $Script:ProvisionState.PowerShell  = $ps
    $Script:ProvisionState.AsyncHandle = $ps.BeginInvoke()
    $Script:ProvisionState.Queue       = $queue
    $Script:ProvisionState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $item = $null
        while ($Script:ProvisionState.Queue.TryDequeue([ref]$item)) {
            if (-not $item -or [string]::IsNullOrEmpty($item.IP)) {
                if ($item.__error) {
                    [System.Windows.MessageBox]::Show("Provision failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                }
                continue
            }
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Provision failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }
            $row = $Script:ProvisionState.RowsByIP[$item.IP]
            if (-not $row) { continue }
            if ($item.__progress) {
                $row.Status = $item.Status
            } else {
                $row.Status    = $item.Status
                $row.Success   = $item.Success
                $row.Response  = $item.Response
                $row.Timestamp = $item.Timestamp
            }
        }
        $Script:UI.ProvisionGrid.Items.Refresh()
        Update-ProvisionSummary

        if ($Script:ProvisionState.DoneRef.Value -and $Script:ProvisionState.Queue.IsEmpty) {
            Stop-ProvisionRunspace
            Set-ProvisionControls $false
            Save-ProvisionCsv
            $ok = ($Script:ProvisionState.Rows | Where-Object Success -eq 'True').Count
            $Script:UI.ProvisionProgressText.Text = "Done. $ok succeeded."
            Update-Status "Provisioning complete. $ok succeeded. Saved $($Script:AppState.ProvisionCsv)"
        }
    })
    $timer.Start()
    $Script:ProvisionState.Timer = $timer
}

function Stop-Provision {
    if (-not $Script:ProvisionState.IsRunning) { return }
    Stop-ProvisionRunspace
    Set-ProvisionControls $false
    $Script:UI.ProvisionProgressText.Text = 'Cancelled.'
    Update-Status 'Provisioning cancelled.'
}

# Auto-load when the Provision tab is activated
$Script:UI.ProvisionTab.Add_GotFocus({
    if ($Script:ProvisionState.Rows.Count -eq 0) { Load-ProvisionFromScan }
})

# Buttons
$Script:UI.ProvisionStartButton.Add_Click({ Start-Provision })
$Script:UI.ProvisionReloadButton.Add_Click({ Load-ProvisionFromScan })
$Script:UI.ProvisionCancelButton.Add_Click({ Stop-Provision })

$Script:UI.ProvisionSelectAll.Add_Checked({
    foreach ($r in $Script:ProvisionState.Rows) { $r.Selected = $true }
    $Script:UI.ProvisionGrid.Items.Refresh()
    Update-ProvisionSummary
})
$Script:UI.ProvisionSelectAll.Add_Unchecked({
    foreach ($r in $Script:ProvisionState.Rows) { $r.Selected = $false }
    $Script:UI.ProvisionGrid.Items.Refresh()
    Update-ProvisionSummary
})

$Script:UI.ProvisionGrid.Add_CellEditEnding({ Update-ProvisionSummary })

# Augment window-close cleanup to include Provision runspace
$window.Add_Closed({ Stop-ProvisionRunspace })

# =============================================================================
# Verify tab
# =============================================================================

$Script:VerifyState = [pscustomobject]@{
    Rows         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    RowsByIP     = @{}
    Runspace     = $null
    PowerShell   = $null
    AsyncHandle  = $null
    Timer        = $null
    Queue        = $null
    DoneRef      = $null
    IsRunning    = $false
}
$Script:UI.VerifyGrid.ItemsSource = $Script:VerifyState.Rows

function Update-VerifySummary {
    $count    = $Script:VerifyState.Rows.Count
    $selected = ($Script:VerifyState.Rows | Where-Object Selected).Count
    $ok       = ($Script:VerifyState.Rows | Where-Object { $_.Verified -eq 'True' }).Count
    $fail     = ($Script:VerifyState.Rows | Where-Object { $_.Verified -eq 'False' }).Count
    $Script:UI.VerifySummaryText.Text = "Loaded $count device(s). Selected: $selected. Verified: $ok. Not verified: $fail."
}

function Set-VerifyControls ($isRunning) {
    $Script:VerifyState.IsRunning           = $isRunning
    $Script:UI.VerifyStartButton.IsEnabled  = -not $isRunning
    $Script:UI.VerifyReloadButton.IsEnabled = -not $isRunning
    $Script:UI.VerifyCancelButton.IsEnabled = $isRunning
}

function Load-VerifyFromProvision {
    # Prefer in-memory provisioning results; fall back to CSV.
    $Script:VerifyState.Rows.Clear()
    $Script:VerifyState.RowsByIP.Clear()

    $source = @()
    if ($Script:ProvisionState.Rows.Count -gt 0) {
        # Successes only by default (matches CLI Test-CrestronAdmin behavior)
        $source = $Script:ProvisionState.Rows |
            Where-Object { $_.Success -eq 'True' } |
            ForEach-Object { [pscustomobject]@{ IP = $_.IP; Selected = $true } }
    } elseif (Test-Path $Script:AppState.ProvisionCsv) {
        try {
            $source = Import-Csv $Script:AppState.ProvisionCsv |
                Where-Object { $_.IP -and $_.Success -eq 'True' } |
                ForEach-Object { [pscustomobject]@{ IP = $_.IP; Selected = $true } }
        } catch {
            Update-Status "Could not read $($Script:AppState.ProvisionCsv): $($_.Exception.Message)"
            return
        }
    } else {
        Update-Status 'No provisioning results to load. Provision devices first.'
        Update-VerifySummary
        return
    }

    foreach ($s in $source) {
        $row = [pscustomobject]@{
            Selected  = [bool]$s.Selected
            IP        = $s.IP
            Verified  = ''
            State     = ''
            Detail    = ''
            CheckedAt = ''
        }
        $Script:VerifyState.Rows.Add($row)
        $Script:VerifyState.RowsByIP[$s.IP] = $row
    }
    Update-VerifySummary
    Update-Status "Loaded $($Script:VerifyState.Rows.Count) device(s) into Verify tab."
}

function Save-VerifyCsv {
    if ($Script:VerifyState.Rows.Count -eq 0) { return }
    $Script:VerifyState.Rows |
        Where-Object Verified -ne '' |
        Select-Object IP, Verified, State, Detail, CheckedAt |
        Export-Csv -NoTypeInformation -Path $Script:AppState.VerifyCsv
}

function Stop-VerifyRunspace {
    if ($Script:VerifyState.Timer) {
        $Script:VerifyState.Timer.Stop()
        $Script:VerifyState.Timer = $null
    }
    if ($Script:VerifyState.PowerShell) {
        try { $Script:VerifyState.PowerShell.Stop() } catch {}
        try { $Script:VerifyState.PowerShell.Dispose() } catch {}
        $Script:VerifyState.PowerShell  = $null
        $Script:VerifyState.AsyncHandle = $null
    }
    if ($Script:VerifyState.Runspace) {
        try { $Script:VerifyState.Runspace.Close() } catch {}
        try { $Script:VerifyState.Runspace.Dispose() } catch {}
        $Script:VerifyState.Runspace = $null
    }
}

function Start-Verify {
    if ($Script:VerifyState.IsRunning) { return }
    $selectedIPs = @($Script:VerifyState.Rows | Where-Object Selected | Select-Object -ExpandProperty IP)
    if ($selectedIPs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No devices selected.", "Nothing to verify", 'OK', 'Warning') | Out-Null
        return
    }

    # Reset selected rows
    foreach ($ip in $selectedIPs) {
        $row = $Script:VerifyState.RowsByIP[$ip]
        if ($row) {
            $row.Verified  = ''
            $row.State     = 'Pending'
            $row.Detail    = ''
            $row.CheckedAt = ''
        }
    }
    $Script:UI.VerifyGrid.Items.Refresh()
    $Script:UI.VerifyProgressText.Text = "Verifying $($selectedIPs.Count) device(s)..."
    Set-VerifyControls $true
    Update-Status "Verifying $($selectedIPs.Count) device(s)..."

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',   $queue)
    $rs.SessionStateProxy.SetVariable('doneRef', $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',     $selectedIPs)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module CrestronAdminBootstrap -Force -ErrorAction Stop
            $results = Test-CrestronAdmin -IP $ips
            foreach ($r in @($results)) {
                $queue.Enqueue([pscustomobject]@{
                    IP        = $r.IP
                    Verified  = "$($r.Verified)"
                    State     = $r.State
                    Detail    = $r.Detail
                    CheckedAt = $r.CheckedAt
                })
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally {
            $doneRef.Value = $true
        }
    })

    $Script:VerifyState.Runspace    = $rs
    $Script:VerifyState.PowerShell  = $ps
    $Script:VerifyState.AsyncHandle = $ps.BeginInvoke()
    $Script:VerifyState.Queue       = $queue
    $Script:VerifyState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $item = $null
        while ($Script:VerifyState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Verify failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }
            $row = $Script:VerifyState.RowsByIP[$item.IP]
            if (-not $row) { continue }
            $row.Verified  = $item.Verified
            $row.State     = $item.State
            $row.Detail    = $item.Detail
            $row.CheckedAt = $item.CheckedAt
        }
        $Script:UI.VerifyGrid.Items.Refresh()
        Update-VerifySummary

        if ($Script:VerifyState.DoneRef.Value -and $Script:VerifyState.Queue.IsEmpty) {
            Stop-VerifyRunspace
            Set-VerifyControls $false
            Save-VerifyCsv
            $ok = ($Script:VerifyState.Rows | Where-Object Verified -eq 'True').Count
            $Script:UI.VerifyProgressText.Text = "Done. $ok verified."
            Update-Status "Verification complete. $ok verified. Saved $($Script:AppState.VerifyCsv)"
        }
    })
    $timer.Start()
    $Script:VerifyState.Timer = $timer
}

function Stop-Verify {
    if (-not $Script:VerifyState.IsRunning) { return }
    Stop-VerifyRunspace
    Set-VerifyControls $false
    $Script:UI.VerifyProgressText.Text = 'Cancelled.'
    Update-Status 'Verify cancelled.'
}

$Script:UI.VerifyTab.Add_GotFocus({
    if ($Script:VerifyState.Rows.Count -eq 0) { Load-VerifyFromProvision }
})

$Script:UI.VerifyStartButton.Add_Click({ Start-Verify })
$Script:UI.VerifyReloadButton.Add_Click({ Load-VerifyFromProvision })
$Script:UI.VerifyCancelButton.Add_Click({ Stop-Verify })

$Script:UI.VerifySelectAll.Add_Checked({
    foreach ($r in $Script:VerifyState.Rows) { $r.Selected = $true }
    $Script:UI.VerifyGrid.Items.Refresh()
    Update-VerifySummary
})
$Script:UI.VerifySelectAll.Add_Unchecked({
    foreach ($r in $Script:VerifyState.Rows) { $r.Selected = $false }
    $Script:UI.VerifyGrid.Items.Refresh()
    Update-VerifySummary
})

$Script:UI.VerifyGrid.Add_CellEditEnding({ Update-VerifySummary })

$window.Add_Closed({ Stop-VerifyRunspace })

# =============================================================================
# Blanket Settings tab
# =============================================================================

$Script:BlanketState = [pscustomobject]@{
    Rows         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    RowsByIP     = @{}
    Runspace     = $null
    PowerShell   = $null
    AsyncHandle  = $null
    Timer        = $null
    Queue        = $null
    DoneRef      = $null
    IsRunning    = $false
}
$Script:UI.BlanketGrid.ItemsSource = $Script:BlanketState.Rows

# Populate timezone dropdown. Inlined here because Get-CrestronTimeZones is a
# private module helper (not exported) and the GUI lives outside the module
# scope.
$tzList = @(
    [pscustomobject]@{ Code = '004'; Name = 'Hawaii Standard Time (UTC-10:00)' }
    [pscustomobject]@{ Code = '005'; Name = 'Alaska Standard Time (UTC-09:00)' }
    [pscustomobject]@{ Code = '008'; Name = 'Pacific Time (US & Canada) (UTC-08:00)' }
    [pscustomobject]@{ Code = '009'; Name = 'Mountain Time (US & Canada) (UTC-07:00)' }
    [pscustomobject]@{ Code = '010'; Name = 'Central Time (US & Canada) (UTC-06:00)' }
    [pscustomobject]@{ Code = '014'; Name = 'Eastern Time (US & Canada) (UTC-05:00)' }
    [pscustomobject]@{ Code = '015'; Name = 'Atlantic Time (Canada) (UTC-04:00)' }
    [pscustomobject]@{ Code = '017'; Name = 'Newfoundland (UTC-03:30)' }
    [pscustomobject]@{ Code = '018'; Name = 'Brasilia (UTC-03:00)' }
    [pscustomobject]@{ Code = '019'; Name = 'Buenos Aires (UTC-03:00)' }
    [pscustomobject]@{ Code = '023'; Name = 'UTC / Coordinated Universal Time' }
    [pscustomobject]@{ Code = '025'; Name = 'GMT - London / Dublin / Lisbon (UTC+00:00)' }
    [pscustomobject]@{ Code = '027'; Name = 'Central European Time - Berlin / Paris / Madrid (UTC+01:00)' }
    [pscustomobject]@{ Code = '028'; Name = 'Central European Time - Amsterdam / Brussels / Vienna (UTC+01:00)' }
    [pscustomobject]@{ Code = '029'; Name = 'Central European Time - Belgrade / Prague / Warsaw (UTC+01:00)' }
    [pscustomobject]@{ Code = '030'; Name = 'Eastern European Time - Athens / Helsinki / Istanbul (UTC+02:00)' }
    [pscustomobject]@{ Code = '034'; Name = 'Moscow / St. Petersburg (UTC+03:00)' }
    [pscustomobject]@{ Code = '035'; Name = 'Tehran (UTC+03:30)' }
    [pscustomobject]@{ Code = '036'; Name = 'Abu Dhabi / Muscat (UTC+04:00)' }
    [pscustomobject]@{ Code = '037'; Name = 'Kabul (UTC+04:30)' }
    [pscustomobject]@{ Code = '039'; Name = 'Karachi / Tashkent (UTC+05:00)' }
    [pscustomobject]@{ Code = '040'; Name = 'India Standard Time - Mumbai / Kolkata (UTC+05:30)' }
    [pscustomobject]@{ Code = '044'; Name = 'Bangkok / Hanoi / Jakarta (UTC+07:00)' }
    [pscustomobject]@{ Code = '045'; Name = 'China Standard Time - Beijing / Hong Kong (UTC+08:00)' }
    [pscustomobject]@{ Code = '048'; Name = 'Japan Standard Time - Tokyo / Osaka (UTC+09:00)' }
    [pscustomobject]@{ Code = '049'; Name = 'Korea Standard Time - Seoul (UTC+09:00)' }
    [pscustomobject]@{ Code = '051'; Name = 'Australian Central Time - Adelaide (UTC+09:30)' }
    [pscustomobject]@{ Code = '053'; Name = 'Australian Eastern Time - Sydney / Melbourne (UTC+10:00)' }
    [pscustomobject]@{ Code = '054'; Name = 'Brisbane (UTC+10:00)' }
    [pscustomobject]@{ Code = '055'; Name = 'Hobart (UTC+10:00)' }
    [pscustomobject]@{ Code = '058'; Name = 'Auckland / Wellington (UTC+12:00)' }
)
$Script:UI.NtpTimeZoneBox.ItemsSource = $tzList
$Script:UI.NtpTimeZoneBox.DisplayMemberPath = 'Name'
$Script:UI.NtpTimeZoneBox.SelectedValuePath  = 'Code'
# Default: 010 (Central US) — index 4 in our table; tolerate a different order by code lookup
$defaultTz = $tzList | Where-Object { $_.Code -eq '010' } | Select-Object -First 1
if ($defaultTz) { $Script:UI.NtpTimeZoneBox.SelectedItem = $defaultTz }
elseif ($tzList.Count -gt 0) { $Script:UI.NtpTimeZoneBox.SelectedIndex = 0 }

$Script:UI.AvInputHdcpModeBox.ItemsSource = @('Auto', 'HDCP 1.4', 'HDCP 2.x', 'Never Authenticate')
$Script:UI.AvInputHdcpModeBox.SelectedIndex = 0

$Script:UI.AvOutputHdcpModeBox.ItemsSource = @('Auto', 'FollowInput', 'ForceHighest', 'NeverAuthenticate')
$Script:UI.AvOutputHdcpModeBox.SelectedIndex = 0

$Script:UI.AvOutputResolutionBox.ItemsSource = @(
    'Auto',
    '3840x2160@60',
    '3840x2160@30',
    '1920x1080@60',
    '1920x1080@30',
    '1280x720@60'
)
$Script:UI.AvOutputResolutionBox.SelectedIndex = 0

$Script:UI.AvGlobalEdidTypeBox.ItemsSource = @('Copy', 'System', 'Custom')
$Script:UI.AvGlobalEdidTypeBox.SelectedIndex = 1

function Update-AvGlobalEdidOptions {
    if (-not $Script:UI.AvGlobalEdidNameBox) {
        return
    }

    $currentText = "$($Script:UI.AvGlobalEdidNameBox.Text)"
    $names = @()

    foreach ($row in @($Script:BlanketState.Rows)) {
        if ($row.PSObject.Properties.Name -contains 'EdidNames' -and $row.EdidNames) {
            $names += @("$($row.EdidNames)" -split '\|' | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })
        }
    }

    $names = @($names | Sort-Object -Unique)

    if ($names.Count -gt 0) {
        $Script:UI.AvGlobalEdidNameBox.ItemsSource = $names

        if (-not [string]::IsNullOrWhiteSpace($currentText)) {
            $Script:UI.AvGlobalEdidNameBox.Text = $currentText
        }
        else {
            $Script:UI.AvGlobalEdidNameBox.Text = "$($names[0])"
        }
    }
}

function Update-BlanketSummary {
    $count = $Script:BlanketState.Rows.Count
    $selected = ($Script:BlanketState.Rows | Where-Object Selected).Count
    $ok = ($Script:BlanketState.Rows | Where-Object { $_.Status -eq 'OK' }).Count
    $fail = ($Script:BlanketState.Rows | Where-Object { $_.Status -and $_.Status -notin 'OK','Pending','Working' }).Count
    $reboot = ($Script:BlanketState.Rows | Where-Object NeedsReboot).Count

    $Script:UI.BlanketSummaryText.Text = "Loaded $count device(s). Selected: $selected. OK: $ok. Failed: $fail. Reboot needed: $reboot."

    if ($Script:UI.BlanketRebootButton) {
        $Script:UI.BlanketRebootButton.IsEnabled = ($reboot -gt 0)
    }
}

function Set-BlanketControls ($isRunning) {
    $Script:BlanketState.IsRunning            = $isRunning
    $Script:UI.BlanketApplyButton.IsEnabled   = -not $isRunning
    $Script:UI.BlanketReloadButton.IsEnabled  = -not $isRunning
    $Script:UI.BlanketCancelButton.IsEnabled  = $isRunning
    $Script:UI.BlanketCapabilityButton.IsEnabled = -not $isRunning
}

function Load-BlanketFromProvision {
    $Script:BlanketState.Rows.Clear()
    $Script:BlanketState.RowsByIP.Clear()

    $source = @()
    if ($Script:ProvisionState.Rows.Count -gt 0) {
        $source = $Script:ProvisionState.Rows |
            Where-Object { $_.Success -eq 'True' } |
            ForEach-Object { [pscustomobject]@{ IP = $_.IP } }
    } elseif (Test-Path $Script:AppState.ProvisionCsv) {
        try {
            $source = Import-Csv $Script:AppState.ProvisionCsv |
                Where-Object { $_.IP -and $_.Success -eq 'True' } |
                ForEach-Object { [pscustomobject]@{ IP = $_.IP } }
        } catch {
            Update-Status "Could not read $($Script:AppState.ProvisionCsv): $($_.Exception.Message)"
            return
        }
    } else {
        Update-Status 'No provisioning results. Provision devices first.'
        Update-BlanketSummary
        return
    }

    foreach ($s in $source) {
        $row = [pscustomobject]@{
            Selected            = $true
            IP                  = $s.IP
            Model                = ''
            CurrentDeviceMode    = ''
            AvApiFamily          = ''
            AvApiVersion         = ''
            SupportsAvSettings   = $false
            SupportsAvMulticast  = $false
            SupportsGlobalEdid   = $false
            EdidNames            = ''
            SupportsModeChange   = $false
            SupportsNtp          = $false
            SupportsCloud        = $false
            SupportsFusion       = $false
            SupportsAutoUpdate   = $false
            SupportsIpTable      = $false
            SupportsNetwork      = $false
            SupportsWifi         = $false
            CapabilitiesFetched  = $false
            Status              = ''
            Sections            = ''
            Detail              = ''
            NeedsReboot         = $false
            Timestamp           = ''
        }

        $Script:BlanketState.Rows.Add($row)
        $Script:BlanketState.RowsByIP[$s.IP] = $row
    }

    Update-BlanketSummary
    Update-Status "Loaded $($Script:BlanketState.Rows.Count) device(s) into Blanket Settings tab."
}

function Save-BlanketCsv {
    if ($Script:BlanketState.Rows.Count -eq 0) { return }

    $Script:BlanketState.Rows |
        Where-Object Status -ne '' |
        Select-Object IP, Model, CurrentDeviceMode,
                      AvApiFamily, AvApiVersion, SupportsAvSettings, SupportsAvMulticast, SupportsGlobalEdid,
                      EdidNames,
                      SupportsNtp, SupportsCloud, SupportsFusion, SupportsAutoUpdate,
                      SupportsIpTable, SupportsNetwork, SupportsWifi, SupportsModeChange,
                      CapabilitiesFetched,
                      Status, Sections, Detail, NeedsReboot, Timestamp |
        Export-Csv -NoTypeInformation -Path $Script:AppState.SettingsCsv
}

function Stop-BlanketRunspace {
    if ($Script:BlanketState.Timer) {
        $Script:BlanketState.Timer.Stop()
        $Script:BlanketState.Timer = $null
    }
    if ($Script:BlanketState.PowerShell) {
        try { $Script:BlanketState.PowerShell.Stop() } catch {}
        try { $Script:BlanketState.PowerShell.Dispose() } catch {}
        $Script:BlanketState.PowerShell  = $null
        $Script:BlanketState.AsyncHandle = $null
    }
    if ($Script:BlanketState.Runspace) {
        try { $Script:BlanketState.Runspace.Close() } catch {}
        try { $Script:BlanketState.Runspace.Dispose() } catch {}
        $Script:BlanketState.Runspace = $null
    }
}

function Start-BlanketCapabilityFetch {
    if ($Script:BlanketState.IsRunning) { return }

    $ips = @($Script:BlanketState.Rows | Select-Object -ExpandProperty IP)

    if ($ips.Count -eq 0) {
        Update-Status 'No Blanket Settings devices loaded.'
        return
    }

    $cred = Get-CachedCredential
    if (-not $cred) {
        Update-Status 'Capability fetch cancelled (no credentials).'
        return
    }

    foreach ($row in $Script:BlanketState.Rows) {
        $row.Status = 'Pending'
        $row.Detail = ''
        $row.Timestamp = ''
    }

    $Script:UI.BlanketGrid.Items.Refresh()
    $Script:UI.BlanketProgressText.Text = "Fetching capabilities for $($ips.Count) device(s)..."
    Set-BlanketControls $true
    Update-Status "Fetching Blanket Settings capabilities..."

    $modManifest = (Get-Module CrestronAdminBootstrap).Path

    if (-not $modManifest) {
        $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap |
            Sort-Object Version -Descending |
            Select-Object -First 1).Path
    }

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('queue',    $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',  $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',      $ips)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip = $_
                $q  = $using:queue
                $u  = $using:userName
                $p  = $using:userPass
                $mp = $using:manifest

                $q.Enqueue([pscustomobject]@{
                    __progress = $true
                    IP         = $ip
                    Status     = 'Working'
                })

                try {
                    if (-not $mp -or -not (Test-Path $mp)) {
                        throw "Module manifest path missing: '$mp'"
                    }

                    Import-Module $mp -Force -ErrorAction Stop

                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred

                    try {
                        $caps = Get-CrestronDeviceCapabilities -Session $sess

                        $q.Enqueue([pscustomobject]@{
                            __result            = $true
                            IP                  = $ip
                            Model               = $caps.Model
                            CurrentDeviceMode   = $caps.CurrentDeviceMode
                            AvApiFamily         = "$($caps.AvApiFamily)"
                            AvApiVersion        = "$($caps.AvApiVersion)"
                            SupportsAvSettings  = [bool]$caps.SupportsAvSettings
                            SupportsAvMulticast = [bool]$caps.SupportsAvMulticast
                            SupportsGlobalEdid  = [bool]$caps.SupportsGlobalEdid
                            EdidNames           = (@($caps.EdidNames) -join '|')
                            SupportsModeChange  = [bool]$caps.SupportsModeChange
                            SupportsNtp         = [bool]$caps.SupportsNtp
                            SupportsCloud       = [bool]$caps.SupportsCloud
                            SupportsFusion      = [bool]$caps.SupportsFusion
                            SupportsAutoUpdate  = [bool]$caps.SupportsAutoUpdate
                            SupportsIpTable     = [bool]$caps.SupportsIpTable
                            SupportsNetwork     = [bool]$caps.SupportsNetwork
                            SupportsWifi        = [bool]$caps.SupportsWifi
                            CapabilitiesFetched = $true
                            Status              = 'OK'
                            Detail              = 'Capabilities fetched'
                            Timestamp           = (Get-Date).ToString('s')
                        })
                    }
                    finally {
                        Disconnect-CrestronDevice -Session $sess
                    }
                }
                catch {
                    $q.Enqueue([pscustomobject]@{
                        __result            = $true
                        IP                  = $ip
                        Model               = ''
                        CurrentDeviceMode   = ''
                        AvApiFamily         = ''
                        AvApiVersion        = ''
                        SupportsAvSettings  = $false
                        SupportsAvMulticast = $false
                        SupportsGlobalEdid  = $false
                        EdidNames           = ''
                        SupportsModeChange  = $false
                        SupportsNtp         = $false
                        SupportsCloud       = $false
                        SupportsFusion      = $false
                        SupportsAutoUpdate  = $false
                        SupportsIpTable     = $false
                        SupportsNetwork     = $false
                        SupportsWifi        = $false
                        CapabilitiesFetched = $false
                        Status              = 'Error'
                        Detail              = "ERROR: $($_.Exception.Message)"
                        Timestamp           = (Get-Date).ToString('s')
                    })
                }
            }
        }
        catch {
            $queue.Enqueue([pscustomobject]@{
                __error = $_.Exception.Message
            })
        }
        finally {
            $doneRef.Value = $true
        }
    })

    $Script:BlanketState.Runspace    = $rs
    $Script:BlanketState.PowerShell  = $ps
    $Script:BlanketState.AsyncHandle = $ps.BeginInvoke()
    $Script:BlanketState.Queue       = $queue
    $Script:BlanketState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)

    $timer.Add_Tick({
        $item = $null

        while ($Script:BlanketState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Capability fetch failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }

            $row = $Script:BlanketState.RowsByIP[$item.IP]
            if (-not $row) { continue }

            foreach ($prop in @(
                'Model',
                'CurrentDeviceMode',
                'AvApiFamily',
                'AvApiVersion',
                'SupportsAvSettings',
                'SupportsAvMulticast',
                'SupportsGlobalEdid',
                'EdidNames',
                'SupportsModeChange',
                'SupportsNtp',
                'SupportsCloud',
                'SupportsFusion',
                'SupportsAutoUpdate',
                'SupportsIpTable',
                'SupportsNetwork',
                'SupportsWifi',
                'CapabilitiesFetched',
                'NeedsReboot'
            )) {
                if (-not ($row.PSObject.Properties.Name -contains $prop)) {
                    $defaultValue = switch ($prop) {
                        'Model'               { '' }
                        'CurrentDeviceMode'   { '' }
                        'AvApiFamily'         { '' }
                        'AvApiVersion'        { '' }
                        'SupportsAvSettings'  { $false }
                        'SupportsAvMulticast' { $false }
                        'SupportsGlobalEdid'  { $false }
                        'EdidNames'           { '' }
                        'SupportsModeChange'  { $false }
                        'SupportsNtp'         { $false }
                        'SupportsCloud'       { $false }
                        'SupportsFusion'      { $false }
                        'SupportsAutoUpdate'  { $false }
                        'SupportsIpTable'     { $false }
                        'SupportsNetwork'     { $false }
                        'SupportsWifi'        { $false }
                        'CapabilitiesFetched' { $false }
                        'NeedsReboot'         { $false }
                    }

                    $row | Add-Member -NotePropertyName $prop -NotePropertyValue $defaultValue -Force
                }
            }

            $row.Status = $item.Status

            if (-not $item.__progress) {
                $row.Model               = "$($item.Model)"
                $row.CurrentDeviceMode   = "$($item.CurrentDeviceMode)"
                $row.AvApiFamily         = "$($item.AvApiFamily)"
                $row.AvApiVersion        = "$($item.AvApiVersion)"
                $row.SupportsAvSettings  = [bool]$item.SupportsAvSettings
                $row.SupportsAvMulticast = [bool]$item.SupportsAvMulticast
                $row.SupportsGlobalEdid  = [bool]$item.SupportsGlobalEdid
                $row.EdidNames           = "$($item.EdidNames)"
                $row.SupportsModeChange  = [bool]$item.SupportsModeChange
                $row.SupportsNtp         = [bool]$item.SupportsNtp
                $row.SupportsCloud       = [bool]$item.SupportsCloud
                $row.SupportsFusion      = [bool]$item.SupportsFusion
                $row.SupportsAutoUpdate  = [bool]$item.SupportsAutoUpdate
                $row.SupportsIpTable     = [bool]$item.SupportsIpTable
                $row.SupportsNetwork     = [bool]$item.SupportsNetwork
                $row.SupportsWifi        = [bool]$item.SupportsWifi
                $row.CapabilitiesFetched = [bool]$item.CapabilitiesFetched
                $row.Detail              = $item.Detail
                $row.Timestamp           = $item.Timestamp
            }
        }

        $Script:UI.BlanketGrid.Items.Refresh()
        Update-BlanketSummary

        if ($Script:BlanketState.DoneRef.Value -and $Script:BlanketState.Queue.IsEmpty) {
            Stop-BlanketRunspace
            Set-BlanketControls $false
            Save-BlanketCsv

            $ok = ($Script:BlanketState.Rows | Where-Object Status -eq 'OK').Count
            $Script:UI.BlanketProgressText.Text = "Capability fetch complete. $ok device(s) OK."
            Update-Status "Blanket capability fetch complete. $ok OK."
            Update-AvGlobalEdidOptions
        }
    })

    $timer.Start()
    $Script:BlanketState.Timer = $timer
}

function Test-ResultNeedsReboot {
    param(
        $Result
    )

    if (-not $Result) {
        return $false
    }

    if ($Result.PSObject.Properties.Name -contains 'NeedsReboot') {
        if ([bool]$Result.NeedsReboot) {
            return $true
        }
    }

    if ($Result.PSObject.Properties.Name -contains 'SectionResults' -and $Result.SectionResults) {
        foreach ($sr in @($Result.SectionResults)) {
            if ($sr.PSObject.Properties.Name -contains 'StatusId') {
                try {
                    if ([int]$sr.StatusId -eq 1) {
                        return $true
                    }
                }
                catch { }
            }

            if ("$($sr.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                return $true
            }

            if ("$($sr.Response)" -match '(?i)reboot|restart|power cycle') {
                return $true
            }
        }
    }

    if ("$($Result.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
        return $true
    }

    if ("$($Result.Response)" -match '(?i)reboot|restart|power cycle') {
        return $true
    }

    return $false
}

$Script:SuppressRebootNeededNotice = $false

function Show-RebootNeededNotice {
    param(
        [int]$Count,
        [string]$AreaName = 'this tab'
    )

    if ($Script:SuppressRebootNeededNotice) {
        return 'None'
    }

    if ($Count -le 0) {
        return 'None'
    }

    $result = [System.Windows.MessageBox]::Show(
        "$Count device(s) require a reboot for changes to take effect.`n`nThe Reboot? box has been checked automatically.`n`nReboot now?",
        "Reboot required",
        'YesNo',
        'Warning'
    )

    if ($result -eq 'Yes') {
        Update-Status "$Count device(s) in $AreaName require reboot. User chose Reboot Now."
        return 'RebootNow'
    }

    Update-Status "$Count device(s) in $AreaName require reboot. Reboot later selected."
    return 'RebootLater'
}

function Invoke-RebootNeededRows {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [hashtable]$RowsByIP,

        [Parameter(Mandatory)]
        $Grid,

        [Parameter(Mandatory)]
        [scriptblock]$UpdateSummary,

        [Parameter(Mandatory)]
        [string]$AreaName
    )

    $rebootNeeded = @($Rows | Where-Object { [bool]$_.NeedsReboot }).Count

    if ($Script:WorkflowState -and [bool]$Script:WorkflowState.IsRunning) {
        if ($rebootNeeded -gt 0) {
            Update-Status "$rebootNeeded device(s) in $AreaName require reboot. Full Workflow will reboot later."
        }

        return
    }

    $rebootChoice = Show-RebootNeededNotice -Count $rebootNeeded -AreaName $AreaName

    if ($rebootChoice -ne 'RebootNow') {
        return
    }

    $ipsToReboot = @($Rows |
        Where-Object { [bool]$_.NeedsReboot } |
        Select-Object -ExpandProperty IP)

    if ($ipsToReboot.Count -eq 0) {
        Update-Status "Reboot requested, but no $AreaName rows are marked NeedsReboot."
        return
    }

    $statusCallback = {
        param($item)

        $row = $RowsByIP[$item.IP]
        if ($row) {
            $row.Status = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Detail = $item.Detail

            if ($item.Success -eq 'True') {
                $row.NeedsReboot = $false
            }

            $row.Timestamp = (Get-Date).ToString('s')
        }

        $Grid.Items.Refresh()
        & $UpdateSummary
    }.GetNewClosure()

    Invoke-RebootBulk -Ips $ipsToReboot -StatusCallback $statusCallback -SkipConfirm
}
function Start-BlanketApply {
    if ($Script:BlanketState.IsRunning) { return }

    $selectedIPs = @($Script:BlanketState.Rows | Where-Object Selected | Select-Object -ExpandProperty IP)
    if ($selectedIPs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No devices selected.", "Nothing to apply", 'OK', 'Warning') | Out-Null
        return
    }

    # Build the args bag based on which sections are enabled
    $applyNtp    = [bool]$Script:UI.NtpEnableBox.IsChecked
    $applyCloud  = [bool]$Script:UI.CloudEnableBox.IsChecked
    $applyFusion = [bool]$Script:UI.FusionEnableBox.IsChecked
    $applyAuto   = [bool]$Script:UI.AutoUpdateEnableBox.IsChecked
    $applyMode   = [bool]$Script:UI.ModeEnableBox.IsChecked
    $applyInputHdcp = [bool]$Script:UI.AvInputHdcpEnableBox.IsChecked
    $applyOutputHdcp = [bool]$Script:UI.AvOutputHdcpEnableBox.IsChecked
    $applyOutputResolution = [bool]$Script:UI.AvOutputResolutionEnableBox.IsChecked
    $applyGlobalEdid = [bool]$Script:UI.AvGlobalEdidEnableBox.IsChecked

    if (-not (
        $applyNtp -or $applyCloud -or $applyFusion -or $applyAuto -or $applyMode -or
        $applyInputHdcp -or $applyOutputHdcp -or $applyOutputResolution -or $applyGlobalEdid
    )) {
        [System.Windows.MessageBox]::Show("Enable at least one settings section before applying.", "Nothing to apply", 'OK', 'Warning') | Out-Null
        return
    }

    $ntp = $null
    if ($applyNtp) {
        $tzItem = $Script:UI.NtpTimeZoneBox.SelectedItem
        if (-not $tzItem) {
            [System.Windows.MessageBox]::Show("Pick a time zone.", "Missing value", 'OK', 'Warning') | Out-Null
            return
        }

        $server = $Script:UI.NtpServerBox.Text.Trim()
        if (-not $server) { $server = 'time.google.com' }

        $ntp = @{
            TimeZone   = $tzItem.Code
            NtpServer  = $server
            NtpEnabled = $true
        }
    }

    $cloud = $null
    if ($applyCloud) {
        $cloud = [bool]$Script:UI.CloudOnRadio.IsChecked
    }

    $fusion = $null
    if ($applyFusion) {
        $fusion = [bool]$Script:UI.FusionOnRadio.IsChecked
    }

    $autoUpdate = $null
    if ($applyAuto) {
        $autoUpdate = @{
            Enabled = [bool]$Script:UI.AutoUpdateOnRadio.IsChecked
        }
    }

    $deviceMode = $null
    if ($applyMode) {
        $deviceMode = if ([bool]$Script:UI.ModeReceiverRadio.IsChecked) {
            'Receiver'
        } else {
            'Transmitter'
        }
    }

    $inputHdcpMode = if ($applyInputHdcp) { "$($Script:UI.AvInputHdcpModeBox.SelectedItem)" } else { $null }
    $outputHdcpMode = if ($applyOutputHdcp) { "$($Script:UI.AvOutputHdcpModeBox.SelectedItem)" } else { $null }
    $outputResolution = if ($applyOutputResolution) { "$($Script:UI.AvOutputResolutionBox.SelectedItem)" } else { $null }

    $globalEdid = $null
    if ($applyGlobalEdid) {
        $edidName = $Script:UI.AvGlobalEdidNameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($edidName)) {
            [System.Windows.MessageBox]::Show("Enter an EDID name.", "Missing EDID name", 'OK', 'Warning') | Out-Null
            return
        }

        $globalEdid = @{
            EdidName = $edidName
            EdidType = "$($Script:UI.AvGlobalEdidTypeBox.SelectedItem)"
        }
    }

    # Credentials
    $cred = Get-CachedCredential
    if (-not $cred) {
        Update-Status 'Apply cancelled (no credentials).'
        return
    }

    # Summary + confirm
    $bits = @()
    if ($applyNtp)    { $bits += "NTP=$($ntp.NtpServer)/$($ntp.TimeZone)" }
    if ($applyCloud)  { $bits += "Cloud=$(if ($cloud) { 'ON' } else { 'OFF' })" }
    if ($applyFusion) { $bits += "Fusion=$(if ($fusion) { 'ON' } else { 'OFF' })" }
    if ($applyAuto)   { $bits += "AutoUpdate=$(if ($autoUpdate.Enabled) { 'ON' } else { 'OFF' })" }
    if ($applyMode)   { $bits += "Mode=$deviceMode" }
    if ($applyInputHdcp) { $bits += "InputHDCP=$inputHdcpMode" }
    if ($applyOutputHdcp) { $bits += "OutputHDCP=$outputHdcpMode" }
    if ($applyOutputResolution) { $bits += "OutputResolution=$outputResolution" }
    if ($applyGlobalEdid) { $bits += "GlobalEDID=$($globalEdid.EdidType):$($globalEdid.EdidName)" }

    $msg = "Apply [$($bits -join ', ')] to $($selectedIPs.Count) device(s) as '$($cred.UserName)'?"
    $confirm = [System.Windows.MessageBox]::Show($msg, "Confirm apply", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') {
        Update-Status 'Apply cancelled.'
        return
    }

    # Mark selected rows
    foreach ($ip in $selectedIPs) {
        $row = $Script:BlanketState.RowsByIP[$ip]
        if ($row) {
            $row.Status      = 'Pending'
            $row.Sections    = ''
            $row.Detail      = ''
            $row.NeedsReboot = $false
            $row.Timestamp   = ''
        }
    }

    $Script:UI.BlanketGrid.Items.Refresh()
    $Script:UI.BlanketProgressText.Text = "Applying to $($selectedIPs.Count) device(s)..."
    Set-BlanketControls $true
    Update-Status "Applying blanket settings to $($selectedIPs.Count) device(s)..."

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $selectedRows = @($Script:BlanketState.Rows | Where-Object Selected | ForEach-Object {
        @{
            IP                  = $_.IP
            Model               = $_.Model
            AvApiFamily         = $_.AvApiFamily
            AvApiVersion        = $_.AvApiVersion
            SupportsAvSettings  = [bool]$_.SupportsAvSettings
            SupportsAvMulticast = [bool]$_.SupportsAvMulticast
            SupportsGlobalEdid  = [bool]$_.SupportsGlobalEdid
            SupportsNtp         = [bool]$_.SupportsNtp
            SupportsCloud       = [bool]$_.SupportsCloud
            SupportsFusion      = [bool]$_.SupportsFusion
            SupportsAutoUpdate  = [bool]$_.SupportsAutoUpdate
            SupportsModeChange  = [bool]$_.SupportsModeChange
            CapabilitiesFetched = [bool]$_.CapabilitiesFetched
        }
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('queue',        $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',      $doneRef)
    $rs.SessionStateProxy.SetVariable('selectedRows', $selectedRows)
    $rs.SessionStateProxy.SetVariable('userName',     $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass',     $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('ntp',          $ntp)
    $rs.SessionStateProxy.SetVariable('cloudArg',     $cloud)
    $rs.SessionStateProxy.SetVariable('fusionArg',    $fusion)
    $rs.SessionStateProxy.SetVariable('autoUpdate',   $autoUpdate)
    $rs.SessionStateProxy.SetVariable('deviceMode',   $deviceMode)
    $rs.SessionStateProxy.SetVariable('inputHdcpMode', $inputHdcpMode)
    $rs.SessionStateProxy.SetVariable('outputHdcpMode', $outputHdcpMode)
    $rs.SessionStateProxy.SetVariable('outputResolution', $outputResolution)
    $rs.SessionStateProxy.SetVariable('globalEdid', $globalEdid)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            Import-Module CrestronAdminBootstrap -Force -ErrorAction Stop

            $sec     = ConvertTo-SecureString $userPass -AsPlainText -Force
            $credObj = [pscredential]::new($userName, $sec)

            # Resolve the module manifest path once in this runspace; pass it
            # into each parallel worker so they import by absolute path.
            $modManifest = (Get-Module CrestronAdminBootstrap).Path
            if (-not $modManifest) {
                $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap |
                    Sort-Object Version -Descending |
                    Select-Object -First 1).Path
            }

            if (-not $modManifest -or -not (Test-Path $modManifest)) {
                throw "Could not locate CrestronAdminBootstrap module manifest. Reinstall the module."
            }

            $selectedRows | ForEach-Object -ThrottleLimit 16 -Parallel {
                $rowArg   = $_
                $ip       = $rowArg.IP
                $q        = $using:queue
                $cred     = $using:credObj
                $ntpArg   = $using:ntp
                $cArg     = $using:cloudArg
                $fArg     = $using:fusionArg
                $auArg    = $using:autoUpdate
                $modeArg  = $using:deviceMode
                $inHdcpArg = $using:inputHdcpMode
                $outHdcpArg = $using:outputHdcpMode
                $outResArg = $using:outputResolution
                $edidArg  = $using:globalEdid
                $manifest = $using:modManifest

                $q.Enqueue([pscustomobject]@{
                    __progress = $true
                    IP         = $ip
                    Status     = 'Working'
                })

                try {
                    if (-not $manifest -or -not (Test-Path $manifest)) {
                        throw "Manifest path missing or not found: '$manifest'"
                    }

                    Import-Module $manifest -Force -ErrorAction Stop

                    if (-not (Get-Command Connect-CrestronDevice -ErrorAction SilentlyContinue)) {
                        throw "Import-Module ran but Connect-CrestronDevice not exposed. Module path: '$manifest'. Loaded modules: $((Get-Module).Name -join ', ')"
                    }

                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred

                    try {
                        $callArgs = @{
                            Session = $sess
                        }

                    $stepResults = @()
                    $sections = @()
                    $allOk = $true
                    $needsReboot = $false
                    $skippedBeforeApply = @()

                    function Test-ResultNeedsReboot {
                        param(
                            $Result
                        )

                        if (-not $Result) {
                            return $false
                        }

                        if ($Result.PSObject.Properties.Name -contains 'NeedsReboot') {
                            if ([bool]$Result.NeedsReboot) {
                                return $true
                            }
                        }

                        if ($Result.PSObject.Properties.Name -contains 'SectionResults' -and $Result.SectionResults) {
                            foreach ($sr in @($Result.SectionResults)) {
                                if ($sr.PSObject.Properties.Name -contains 'StatusId') {
                                    try {
                                        if ([int]$sr.StatusId -eq 1) {
                                            return $true
                                        }
                                    }
                                    catch { }
                                }

                                if ("$($sr.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                                    return $true
                                }

                                if ("$($sr.Response)" -match '(?i)reboot|restart|power cycle') {
                                    return $true
                                }
                            }
                        }

                        if ("$($Result.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                            return $true
                        }

                        if ("$($Result.Response)" -match '(?i)reboot|restart|power cycle') {
                            return $true
                        }

                        return $false
                    }

                    function Get-StepResultDetail {
                        param(
                            [Parameter(Mandatory)][string]$Name,
                            [Parameter(Mandatory)]$Result,
                            [string]$Target = ''
                        )

                        $statusText = if ($Result.Success) {
                            'OK'
                        }
                        else {
                            "Status $($Result.Status)"
                        }

                        $text = if ($Target) {
                            "$Name=$statusText -> $Target"
                        }
                        else {
                            "$Name=$statusText"
                        }

                        $failDetails = @($Result.SectionResults |
                            Where-Object { -not [bool]$_.Ok } |
                            Select-Object -First 2 |
                            ForEach-Object { "$($_.Path):$($_.StatusInfo)" })

                        if ($failDetails.Count -gt 0) {
                            return "$text ($($failDetails -join ' | '))"
                        }

                        return $text
                    }

                        if ($ntpArg) {
                            if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsNtp) {
                                $skippedBeforeApply += 'NTP=skipped; unsupported'
                            } else {
                                $callArgs.Ntp = $ntpArg
                            }
                        }

                        if ($null -ne $cArg) {
                            if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsCloud) {
                                $skippedBeforeApply += 'Cloud=skipped; unsupported'
                            } else {
                                $callArgs.Cloud = $cArg
                            }
                        }

                        if ($null -ne $fArg) {
                            if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsFusion) {
                                $skippedBeforeApply += 'Fusion=skipped; unsupported'
                            } else {
                                $callArgs.Fusion = $fArg
                            }
                        }

                        if ($auArg) {
                            if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsAutoUpdate) {
                                $skippedBeforeApply += 'AutoUpdate=skipped; unsupported'
                            } else {
                                $callArgs.AutoUpdate = $auArg
                            }
                        }

                        $stepResults += $skippedBeforeApply

                        if ($callArgs.Keys.Count -gt 1) {
                            $r = Set-CrestronSettings @callArgs

                            if (-not $r.Success) {
                                $allOk = $false
                            }

                            $sections += @($r.AppliedSections)

                            if (Test-ResultNeedsReboot $r) {
                                $needsReboot = $true
                            }

                            $stepResults += ($r.SectionResults | ForEach-Object {
                                "$($_.Path):$($_.StatusInfo)"
                            })
                        }

                        if ($modeArg) {
                            try {
                                if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsModeChange) {
                                    $stepResults += "DeviceMode=skipped; unsupported on $($rowArg.Model)"
                                } else {
                                    $state = Get-CrestronDeviceState -Session $sess

                                    if (-not $state.SupportsModeChange) {
                                        $stepResults += "DeviceMode=skipped; unsupported on $($state.Model)"
                                    }
                                    elseif ($state.CurrentDeviceMode -eq $modeArg) {
                                        $sections += 'DeviceMode'
                                        $stepResults += "DeviceMode=already $modeArg"
                                    }
                                    else {
                                        $rMode = Set-CrestronDeviceMode -Session $sess -Mode $modeArg

                                        if (-not $rMode.Success) {
                                            $allOk = $false
                                        }

                                        if ($rMode.NeedsReboot) {
                                            $needsReboot = $true
                                        }

                                        $sections += 'DeviceMode'
                                        $stepResults += "DeviceMode=$(if ($rMode.Success) { 'OK' } else { $rMode.Status }) -> $modeArg"
                                    }
                                }
                            }
                            catch {
                                $allOk = $false
                                $stepResults += "DeviceMode=ERR: $($_.Exception.Message)"
                            }
                        }

                        if ($inHdcpArg) {
                            try {
                                if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsAvSettings) {
                                    $stepResults += "InputHdcp=skipped; unsupported on $($rowArg.Model)"
                                }
                                else {
                                    $rInHdcp = Set-CrestronInputHdcp -Session $sess -Mode $inHdcpArg

                                    if (-not $rInHdcp.Success) {
                                        $allOk = $false
                                    }

                                    if (Test-ResultNeedsReboot $rInHdcp) {
                                        $needsReboot = $true
                                    }

                                    $sections += 'InputHdcp'
                                    $stepResults += Get-StepResultDetail -Name 'InputHdcp' -Result $rInHdcp -Target $inHdcpArg
                                }
                            }
                            catch {
                                $allOk = $false
                                $stepResults += "InputHdcp=ERR: $($_.Exception.Message)"
                            }
                        }

                        if ($outHdcpArg) {
                            try {
                                if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsAvSettings) {
                                    $stepResults += "OutputHdcp=skipped; unsupported on $($rowArg.Model)"
                                }
                                else {
                                    $rOutHdcp = Set-CrestronOutputHdcp -Session $sess -Mode $outHdcpArg

                                    if (-not $rOutHdcp.Success) {
                                        $allOk = $false
                                    }

                                    if (Test-ResultNeedsReboot $rOutHdcp) {
                                        $needsReboot = $true
                                    }

                                    $sections += 'OutputHdcp'
                                    $stepResults += Get-StepResultDetail -Name 'OutputHdcp' -Result $rOutHdcp -Target $outHdcpArg
                                }
                            }
                            catch {
                                $allOk = $false
                                $stepResults += "OutputHdcp=ERR: $($_.Exception.Message)"
                            }
                        }

                        if ($outResArg) {
                            try {
                                if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsAvSettings) {
                                    $stepResults += "OutputResolution=skipped; unsupported on $($rowArg.Model)"
                                }
                                else {
                                    $rOutRes = Set-CrestronOutputResolution -Session $sess -Resolution $outResArg

                                    if (-not $rOutRes.Success) {
                                        $allOk = $false
                                    }

                                    if (Test-ResultNeedsReboot $rOutRes) {
                                        $needsReboot = $true
                                    }

                                    $sections += 'OutputResolution'
                                    $stepResults += Get-StepResultDetail -Name 'OutputResolution' -Result $rOutRes -Target $outResArg
                                }
                            }
                            catch {
                                $allOk = $false
                                $stepResults += "OutputResolution=ERR: $($_.Exception.Message)"
                            }
                        }

                        if ($edidArg) {
                            try {
                                if ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsAvSettings) {
                                    $stepResults += "GlobalEdid=skipped; unsupported on $($rowArg.Model)"
                                }
                                elseif ($rowArg.CapabilitiesFetched -and -not $rowArg.SupportsGlobalEdid) {
                                    $stepResults += "GlobalEdid=skipped; requires AudioVideoInputOutput 2.5.0+ or AvioV2 (device: $($rowArg.AvApiFamily) $($rowArg.AvApiVersion))"
                                }
                                else {
                                    $rEdid = Set-CrestronGlobalEdid `
                                        -Session $sess `
                                        -EdidName $edidArg.EdidName `
                                        -EdidType $edidArg.EdidType

                                    if (-not $rEdid.Success) {
                                        $allOk = $false
                                    }

                                    if (Test-ResultNeedsReboot $rEdid) {
                                        $needsReboot = $true
                                    }

                                    $sections += 'GlobalEdid'
                                    $stepResults += Get-StepResultDetail `
                                        -Name 'GlobalEdid' `
                                        -Result $rEdid `
                                        -Target "$($edidArg.EdidType):$($edidArg.EdidName)"
                                }
                            }
                            catch {
                                $allOk = $false
                                $stepResults += "GlobalEdid=ERR: $($_.Exception.Message)"
                            }
                        }

                        if ($needsReboot) {
                            $stepResults += "REBOOT NEEDED"
                        }

                        $q.Enqueue([pscustomobject]@{
                            __result    = $true
                            IP          = $ip
                            Status      = if ($allOk) { 'OK' } else { 'Partial' }
                            Sections    = (($sections | Where-Object { $_ }) -join ', ')
                            Detail      = ($stepResults -join '; ')
                            NeedsReboot = $needsReboot
                            Timestamp   = (Get-Date).ToString('s')
                        })
                    }
                    finally {
                        if ($sess) {
                            Disconnect-CrestronDevice -Session $sess
                        }
                    }
                }
                catch {
                    $q.Enqueue([pscustomobject]@{
                        __result    = $true
                        IP          = $ip
                        Status      = 'Error'
                        Sections    = ''
                        Detail      = "ERROR: $($_.Exception.Message)"
                        NeedsReboot = $false
                        Timestamp   = (Get-Date).ToString('s')
                    })
                }
            }
        }
        catch {
            $queue.Enqueue([pscustomobject]@{
                __error = $_.Exception.Message
            })
        }
        finally {
            $doneRef.Value = $true
        }
    })

    $Script:BlanketState.Runspace    = $rs
    $Script:BlanketState.PowerShell  = $ps
    $Script:BlanketState.AsyncHandle = $ps.BeginInvoke()
    $Script:BlanketState.Queue       = $queue
    $Script:BlanketState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)

    $timer.Add_Tick({
        $item = $null

        while ($Script:BlanketState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Apply failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }

            $row = $Script:BlanketState.RowsByIP[$item.IP]
            if (-not $row) { continue }

            if (-not ($row.PSObject.Properties.Name -contains 'NeedsReboot')) {
                $row | Add-Member -NotePropertyName NeedsReboot -NotePropertyValue $false -Force
            }

            $row.Status = $item.Status

            if (-not $item.__progress) {
                $row.Sections    = $item.Sections
                $row.Detail      = $item.Detail
                $row.NeedsReboot = [bool]$item.NeedsReboot
                $row.Timestamp   = $item.Timestamp
            }
        }

        $Script:UI.BlanketGrid.Items.Refresh()
        Update-BlanketSummary

        if ($Script:BlanketState.DoneRef.Value -and $Script:BlanketState.Queue.IsEmpty) {
            Stop-BlanketRunspace
            Set-BlanketControls $false
            Save-BlanketCsv

            $ok = ($Script:BlanketState.Rows | Where-Object Status -eq 'OK').Count
            $Script:UI.BlanketProgressText.Text = "Done. $ok device(s) OK."
            Update-Status "Apply complete. $ok device(s) OK. Saved $($Script:AppState.SettingsCsv)"

            Invoke-RebootNeededRows `
                -Rows @($Script:BlanketState.Rows) `
                -RowsByIP $Script:BlanketState.RowsByIP `
                -Grid $Script:UI.BlanketGrid `
                -UpdateSummary { Update-BlanketSummary } `
                -AreaName 'Blanket Settings'
        }
    })

    $timer.Start()
    $Script:BlanketState.Timer = $timer
}

function Stop-BlanketApply {
    if (-not $Script:BlanketState.IsRunning) { return }
    Stop-BlanketRunspace
    Set-BlanketControls $false
    $Script:UI.BlanketProgressText.Text = 'Cancelled.'
    Update-Status 'Apply cancelled.'
}

$Script:UI.BlanketTab.Add_GotFocus({
    if ($Script:BlanketState.Rows.Count -eq 0) { Load-BlanketFromProvision }
})

$Script:UI.BlanketCapabilityButton.Add_Click({
    Start-BlanketCapabilityFetch
})

$Script:UI.BlanketClearButton.Add_Click({
    $count = $Script:BlanketState.Rows.Count
    if ($count -eq 0) {
        Update-Status 'Nothing to clear.'
        return
    }
    $r = [System.Windows.MessageBox]::Show(
        "Remove all $count device(s) from the Blanket Settings tab?",
        "Clear Loaded", 'YesNo', 'Question'
    )
    if ($r -eq 'Yes') {
        $Script:BlanketState.Rows.Clear()
        $Script:BlanketState.RowsByIP.Clear()
        Update-BlanketSummary
        Update-Status "Cleared $count device(s) from Blanket Settings tab."
    }
})
$Script:UI.BlanketApplyButton.Add_Click({ Start-BlanketApply })
$Script:UI.BlanketCancelButton.Add_Click({ Stop-BlanketApply })

$Script:UI.BlanketSelectAll.Add_Checked({
    foreach ($r in $Script:BlanketState.Rows) { $r.Selected = $true }
    $Script:UI.BlanketGrid.Items.Refresh()
    Update-BlanketSummary
})
$Script:UI.BlanketSelectAll.Add_Unchecked({
    foreach ($r in $Script:BlanketState.Rows) { $r.Selected = $false }
    $Script:UI.BlanketGrid.Items.Refresh()
    Update-BlanketSummary
})

$Script:UI.BlanketGrid.Add_CellEditEnding({
    $Script:UI.BlanketGrid.Dispatcher.BeginInvoke([Action]{
        Update-BlanketSummary
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
})

$Script:UI.BlanketGrid.Add_CurrentCellChanged({
    Update-BlanketSummary
})

$Script:UI.SettingsSaveButton.Add_Click({
    if (-not $Script:GuiSettings) {
        $Script:GuiSettings = New-DefaultGuiSettings
    }

    $Script:GuiSettings.DefaultUsername = "$($Script:UI.SettingsDefaultUsernameBox.Text)"
    $Script:GuiSettings.ProtectedDefaultPassword = Protect-GuiSettingPassword $Script:UI.SettingsDefaultPasswordBox.Password
    $Script:GuiSettings.DarkMode = $false

    $subnets = @($Script:UI.SettingsMostUsedSubnetsBox.Text -split "`r?`n" | ForEach-Object {
        $_.Trim()
    } | Where-Object {
        $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
    })

    if ($subnets.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Enter at least one valid CIDR subnet, for example 192.168.20.0/24.",
            "Invalid subnets",
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $Script:GuiSettings.MostUsedSubnets = $subnets

    Save-GuiSettings
    Initialize-ScanCidrs

    $Script:UI.SettingsStatusText.Text = "Saved."
    Update-Status "GUI settings saved."
})

$Script:UI.SettingsClearPasswordButton.Add_Click({
    if (-not $Script:GuiSettings) {
        $Script:GuiSettings = New-DefaultGuiSettings
    }

    $Script:GuiSettings.ProtectedDefaultPassword = ''
    $Script:UI.SettingsDefaultPasswordBox.Password = ''

    Save-GuiSettings

    $Script:UI.SettingsStatusText.Text = "Saved password cleared."
    Update-Status "Saved default password cleared."
})

$window.Add_Closed({ Stop-BlanketRunspace })

# =============================================================================
# Per-Device tab
# =============================================================================

$Script:PerDeviceState = [pscustomobject]@{
    Rows          = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    RowsByIP      = @{}
    AvInputRows   = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    AvOutputRows  = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    MulticastRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    Runspace      = $null
    PowerShell    = $null
    AsyncHandle   = $null
    Timer         = $null
    Queue         = $null
    DoneRef       = $null
    IsRunning     = $false
}
$Script:UI.PerDeviceGrid.ItemsSource = $Script:PerDeviceState.Rows
$Script:UI.PerDeviceAvInputGrid.ItemsSource = $Script:PerDeviceState.AvInputRows
$Script:UI.PerDeviceAvOutputGrid.ItemsSource = $Script:PerDeviceState.AvOutputRows
$Script:UI.PerDeviceMulticastGrid.ItemsSource = $Script:PerDeviceState.MulticastRows

function Test-PerDeviceValue {
    param($Value)

    $text = "$Value"
    return (-not [string]::IsNullOrWhiteSpace($text)) -and ($text -ne 'N/A')
}

function ConvertTo-PerDeviceInputHdcpMode {
    param($Value)

    switch -Regex ("$Value".Trim()) {
        '^(Disabled|Never\s*Authenticate|NeverAuthenticate)$' { 'Never Authenticate'; break }
        '^Enabled$'                                           { 'Auto'; break }
        '^HDCP\s*1(\.x|\.4)?$'                                { 'HDCP 1.4'; break }
        '^HDCP\s*2(\.x|\.0|\.2)?$'                            { 'HDCP 2.x'; break }
        default                                               { "$Value" }
    }
}

function Test-PerDeviceInputHdcpMode {
    param($Value)

    return "$Value" -in @(
        'Auto',
        'HDCP 1.4',
        'HDCP 2.x',
        'Never Authenticate',
        'Disabled',
        'Enabled',
        'HDCP 1.x',
        'HDCP 2.0',
        'HDCP 2.2',
        'NeverAuthenticate'
    )
}

function ConvertTo-PerDeviceOutputHdcpMode {
    param($Value)

    switch -Regex ("$Value".Trim()) {
        '^Follow\s*Input$'        { 'FollowInput'; break }
        '^Force\s*Highest$'       { 'ForceHighest'; break }
        '^Never\s*Authenticate$'  { 'NeverAuthenticate'; break }
        default                   { "$Value" }
    }
}

function Get-PerDeviceCurrentMulticastAddress {
    param($Row)

    if (-not $Row) {
        return ''
    }

    $mode = "$($Row.CurrentDeviceMode)"

    if ($mode -eq 'Receiver') {
        return "$($Row.CurrentReceiveMulticast)"
    }

    if ($mode -eq 'Transmitter') {
        return "$($Row.CurrentTransmitMulticast)"
    }

    if (Test-PerDeviceValue $Row.CurrentTransmitMulticast) {
        return "$($Row.CurrentTransmitMulticast)"
    }

    return "$($Row.CurrentReceiveMulticast)"
}

function Remove-PerDeviceSectionRowsByIP {
    param(
        [Parameter(Mandatory)]
        $Collection,

        [Parameter(Mandatory)]
        [string]$IP
    )

    for ($i = $Collection.Count - 1; $i -ge 0; $i--) {
        if ("$($Collection[$i].IP)" -eq $IP) {
            $Collection.RemoveAt($i)
        }
    }
}

function Test-PerDeviceAvInputChanged {
    param($Row)

    if (-not $Row) { return $false }

    $hdcpChanged = (Test-PerDeviceInputHdcpMode $Row.NewInputHdcp) -and
                   "$($Row.NewInputHdcp)" -ne "$($Row.CurrentInputHdcp)"
    $edidChanged = (Test-PerDeviceValue $Row.NewEdidName) -and
                   "$($Row.NewEdidName)" -ne "$($Row.CurrentEdid)"

    return ($hdcpChanged -or $edidChanged)
}

function Test-PerDeviceAvOutputChanged {
    param($Row)

    if (-not $Row) { return $false }

    $hdcpChanged = ($Row.NewOutputHdcp -in 'Auto','FollowInput','ForceHighest','NeverAuthenticate') -and
                   "$($Row.NewOutputHdcp)" -ne "$($Row.CurrentOutputHdcp)"
    $resolutionChanged = (Test-PerDeviceValue $Row.NewOutputResolution) -and
                         "$($Row.NewOutputResolution)" -ne "$($Row.CurrentOutputResolution)"

    return ($hdcpChanged -or $resolutionChanged)
}

function Test-PerDeviceMulticastChanged {
    param($Row)

    if (-not $Row) { return $false }

    return (Test-PerDeviceValue $Row.NewMulticastAddress) -and
           "$($Row.NewMulticastAddress)" -ne "$($Row.CurrentMulticastAddress)"
}

function Update-PerDeviceSummary {
    $count = $Script:PerDeviceState.Rows.Count

    $edited = ($Script:PerDeviceState.Rows | Where-Object {
        $hostnameChanged = (Test-PerDeviceValue $_.NewHostname) -and
                           "$($_.NewHostname)" -ne "$($_.CurrentHostname)"

        $ipModeChanged = $false
        if ($_.IPMode -in 'DHCP','Static') {
            $currentIpMode = if ([bool]$_.CurrentDhcp) {
                'DHCP'
            } else {
                'Static'
            }

            $ipModeChanged = $_.IPMode -ne $currentIpMode
        }

        $deviceModeChanged = $false
        if ($_.DeviceMode -in 'Transmitter','Receiver') {
            $deviceModeChanged = "$($_.DeviceMode)" -ne "$($_.CurrentDeviceMode)"
        }

        $ipTableChanged = ((Test-PerDeviceValue $_.NewIpId) -and "$($_.NewIpId)" -ne "$($_.CurrentIpId)") -or
                          ((Test-PerDeviceValue $_.NewControlSystemAddr) -and "$($_.NewControlSystemAddr)" -ne "$($_.CurrentControlSystemAddr)")

        $networkValueChanged = ((Test-PerDeviceValue $_.NewIP) -and "$($_.NewIP)" -ne "$($_.CurrentIP)") -or
                               ((Test-PerDeviceValue $_.SubnetMask) -and "$($_.SubnetMask)" -ne "$($_.CurrentSubnet)") -or
                               ((Test-PerDeviceValue $_.Gateway) -and "$($_.Gateway)" -ne "$($_.CurrentGateway)") -or
                               ((Test-PerDeviceValue $_.PrimaryDns) -and "$($_.PrimaryDns)" -ne "$($_.CurrentDns1)") -or
                               ((Test-PerDeviceValue $_.SecondaryDns) -and "$($_.SecondaryDns)" -ne "$($_.CurrentDns2)")

        $hostnameChanged -or
        $ipModeChanged -or
        $deviceModeChanged -or
        $ipTableChanged -or
        $networkValueChanged -or
        $_.DisableWifi
    }).Count

    $edited += (@($Script:PerDeviceState.AvInputRows | Where-Object { Test-PerDeviceAvInputChanged $_ })).Count
    $edited += (@($Script:PerDeviceState.AvOutputRows | Where-Object { Test-PerDeviceAvOutputChanged $_ })).Count
    $edited += (@($Script:PerDeviceState.MulticastRows | Where-Object { Test-PerDeviceMulticastChanged $_ })).Count

    $ok = ($Script:PerDeviceState.Rows | Where-Object Status -eq 'OK').Count
    $fail = ($Script:PerDeviceState.Rows | Where-Object { $_.Status -and $_.Status -notin 'OK','Pending','Working' }).Count
    $reboot = ($Script:PerDeviceState.Rows | Where-Object NeedsReboot).Count

    $Script:UI.PerDeviceSummaryText.Text = "Loaded $count device(s). With changes: $edited. OK: $ok. Failed: $fail. Reboot selected: $reboot."

    if ($Script:UI.PerDeviceRebootButton) {
        $Script:UI.PerDeviceRebootButton.IsEnabled = ($reboot -gt 0)
    }
}

function Set-PerDeviceControls ($isRunning) {
    $Script:PerDeviceState.IsRunning              = $isRunning
    $Script:UI.PerDeviceApplyButton.IsEnabled     = -not $isRunning
    $Script:UI.PerDeviceRefreshButton.IsEnabled   = -not $isRunning
    $Script:UI.PerDeviceCancelButton.IsEnabled    = $isRunning
}

function Load-PerDeviceFromProvision {
    $Script:PerDeviceState.Rows.Clear()
    $Script:PerDeviceState.RowsByIP.Clear()
    $Script:PerDeviceState.AvInputRows.Clear()
    $Script:PerDeviceState.AvOutputRows.Clear()
    $Script:PerDeviceState.MulticastRows.Clear()

    $source = @()
    if ($Script:ProvisionState.Rows.Count -gt 0) {
        $source = $Script:ProvisionState.Rows |
            Where-Object { $_.Success -eq 'True' } |
            ForEach-Object { [pscustomobject]@{ IP = $_.IP } }
    } elseif (Test-Path $Script:AppState.ProvisionCsv) {
        try {
            $source = Import-Csv $Script:AppState.ProvisionCsv |
                Where-Object { $_.IP -and $_.Success -eq 'True' } |
                ForEach-Object { [pscustomobject]@{ IP = $_.IP } }
        } catch {
            Update-Status "Could not read $($Script:AppState.ProvisionCsv): $($_.Exception.Message)"
            return
        }
    } else {
        Update-Status 'No provisioning results. Provision devices first.'
        Update-PerDeviceSummary
        return
    }

    foreach ($s in $source) {
        $row = [pscustomobject]@{
            IP                       = $s.IP
            Model                    = ''
            CurrentHostname          = ''
            CurrentDhcp              = $null
            CurrentWifi              = $null
            SupportsNetwork          = $false
            SupportsIpTable          = $false
            HasWifi                  = $false
            CurrentIP                = ''
            CurrentSubnet            = ''
            CurrentGateway           = ''
            CurrentDns1              = ''
            CurrentDns2              = ''
            CurrentIpId              = ''
            CurrentControlSystemAddr = ''
            CurrentRoomId            = ''
            CurrentDeviceMode        = ''
            SupportsModeChange       = $false
            AvApiFamily              = ''
            AvApiVersion             = ''
            SupportsAvSettings       = $false
            SupportsGlobalEdid       = $false
            SupportsInputEdid        = $false
            SupportsEdidEdit         = $false
            EdidNameOptions          = @()
            EdidNames                = ''
            SupportsAvMulticast      = $false
            CurrentTransmitMulticast = ''
            CurrentReceiveMulticast  = ''
            CurrentInputHdcp         = ''
            CurrentOutputHdcp        = ''
            CurrentOutputResolution  = ''
            CurrentGlobalEdid        = ''

            NewHostname              = 'N/A'
            IPMode                   = 'N/A'
            DeviceMode               = 'N/A'
            NewInputHdcp             = 'N/A'
            NewOutputHdcp            = 'N/A'
            NewOutputResolution      = 'N/A'
            NewGlobalEdidName        = 'N/A'
            NewMulticastAddress      = 'N/A'
            MulticastStreamIndex     = 'N/A'
            NewIP                    = 'N/A'
            SubnetMask               = 'N/A'
            Gateway                  = 'N/A'
            PrimaryDns               = 'N/A'
            SecondaryDns             = 'N/A'
            DisableWifi              = $false
            NewIpId                  = 'N/A'
            NewControlSystemAddr     = 'N/A'
            NewRoomId                = ''

            Status                   = ''
            Detail                   = ''
            NeedsReboot              = $false
            Timestamp                = ''
        }

        $Script:PerDeviceState.Rows.Add($row)
        $Script:PerDeviceState.RowsByIP[$s.IP] = $row
    }
    Update-PerDeviceSummary
    Update-Status "Loaded $($Script:PerDeviceState.Rows.Count) device(s) into Per-Device tab."
}

function Save-PerDeviceCsv {
    if ($Script:PerDeviceState.Rows.Count -eq 0) { return }
    $Script:PerDeviceState.Rows |
        Where-Object Status -ne '' |
        Select-Object IP, Model, CurrentHostname, CurrentDeviceMode, SupportsModeChange,
                    SupportsNetwork, SupportsIpTable, HasWifi,
                    AvApiFamily, AvApiVersion, SupportsAvSettings, SupportsGlobalEdid,
                    SupportsInputEdid, SupportsEdidEdit, EdidNames,
                    SupportsAvMulticast, CurrentTransmitMulticast, CurrentReceiveMulticast,
                    CurrentInputHdcp, CurrentOutputHdcp, CurrentOutputResolution, CurrentGlobalEdid,
                    NewHostname, IPMode, DeviceMode,
                    NewInputHdcp, NewOutputHdcp, NewOutputResolution, NewGlobalEdidName,
                    NewMulticastAddress, MulticastStreamIndex,
                    NewIP, SubnetMask, Gateway,
                    PrimaryDns, SecondaryDns, DisableWifi,
                    NewIpId, NewControlSystemAddr, NewRoomId,
                    Status, Detail, NeedsReboot, Timestamp |
        Export-Csv -NoTypeInformation -Path $Script:AppState.PerDeviceCsv
}

function Stop-PerDeviceRunspace {
    if ($Script:PerDeviceState.Timer) {
        $Script:PerDeviceState.Timer.Stop()
        $Script:PerDeviceState.Timer = $null
    }
    if ($Script:PerDeviceState.PowerShell) {
        try { $Script:PerDeviceState.PowerShell.Stop() } catch {}
        try { $Script:PerDeviceState.PowerShell.Dispose() } catch {}
        $Script:PerDeviceState.PowerShell  = $null
        $Script:PerDeviceState.AsyncHandle = $null
    }
    if ($Script:PerDeviceState.Runspace) {
        try { $Script:PerDeviceState.Runspace.Close() } catch {}
        try { $Script:PerDeviceState.Runspace.Dispose() } catch {}
        $Script:PerDeviceState.Runspace = $null
    }
}

# Bulk-fetch device state to pre-fill the grid
function Start-PerDeviceFetch {
    if ($Script:PerDeviceState.IsRunning) { return }

    $ips = @($Script:PerDeviceState.Rows.IP)

    if ($ips.Count -eq 0) {
        Update-Status 'Nothing to fetch — load provisioned devices first.'
        return
    }

    $cred = Get-CachedCredential

    if (-not $cred) {
        Update-Status 'Fetch cancelled (no credentials).'
        return
    }

    $Script:UI.PerDeviceProgressText.Text = "Fetching state for $($ips.Count) device(s)..."
    Set-PerDeviceControls $true
    Update-Status "Fetching device state..."

    $modManifest = (Get-Module CrestronAdminBootstrap).Path

    if (-not $modManifest) {
        $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap |
            Sort-Object Version -Descending |
            Select-Object -First 1).Path
    }

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('queue',    $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',  $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',      $ips)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip = $_
                $q  = $using:queue
                $u  = $using:userName
                $p  = $using:userPass
                $mp = $using:manifest

                try {
                    if (-not $mp -or -not (Test-Path $mp)) {
                        throw "Module manifest path missing: '$mp'"
                    }

                    Import-Module $mp -Force -ErrorAction Stop

                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred

                    try {
                        $state = Get-CrestronDeviceState -Session $sess
                        $av = $null

                        try {
                            $av = Get-CrestronAvSettings -Session $sess
                        }
                        catch {
                            $av = $null
                        }

                        $dnsArr = @($state.DnsServers)
                        $dns1 = if ($dnsArr.Count -ge 1) { $dnsArr[0] } else { '' }
                        $dns2 = if ($dnsArr.Count -ge 2) { $dnsArr[1] } else { '' }
                        $txMulticast = ''
                        $rxMulticast = ''
                        $supportsAvMulticast = $false
                        $supportsAvSettings = $false
                        $supportsGlobalEdid = $false
                        $supportsInputEdid = $false
                        $edidNames = @()
                        $avApiFamily = ''
                        $avApiVersion = ''
                        $currentInputHdcp = ''
                        $currentOutputHdcp = ''
                        $currentOutputResolution = ''
                        $currentGlobalEdid = ''
                        $avInputRows = @()
                        $avOutputRows = @()
                        $multicastRows = @()
                        $modelText = "$($sess.Model)"
                        if ([string]::IsNullOrWhiteSpace($modelText)) {
                            $modelText = "$($state.Model)"
                        }

                        if ($av) {
                            if ([string]::IsNullOrWhiteSpace($modelText)) {
                                $modelText = "$($av.Model)"
                            }

                            $isNvx = $modelText -match '^DM-NVX'
                            $supportsAvMulticast = $isNvx -and ([bool]$av.SupportsStreamTransmit -or [bool]$av.SupportsStreamReceive)
                            $avApiFamily = "$($av.AvApiFamily)"
                            $avApiVersion = "$($av.AvApiVersion)"
                            $supportsAvSettings = -not [string]::IsNullOrWhiteSpace($avApiFamily) -and $avApiFamily -ne 'None'
                            $supportsGlobalEdid = [bool]$av.SupportsGlobalEdid
                            $edidNames = @($av.EdidNames | Where-Object {
                                -not [string]::IsNullOrWhiteSpace("$_")
                            } | Sort-Object -Unique)

                            $txStreams = @($av.TransmitMulticastAddresses)
                            if ($txStreams.Count -gt 0) {
                                $txMulticast = "$($txStreams[0].MulticastAddress)"
                                $multicastRows += [pscustomobject]@{
                                    IP                      = $ip
                                    Direction               = 'Transmit'
                                    StreamIndex             = 0
                                    CurrentMulticastAddress = "$($txStreams[0].MulticastAddress)"
                                    NewMulticastAddress     = "$($txStreams[0].MulticastAddress)"
                                    SupportsAvMulticast     = $supportsAvMulticast
                                }
                            }

                            $rxStreams = @($av.ReceiveMulticastAddresses)
                            if ($rxStreams.Count -gt 0) {
                                $rxMulticast = "$($rxStreams[0].MulticastAddress)"
                                $multicastRows += [pscustomobject]@{
                                    IP                      = $ip
                                    Direction               = 'Receive'
                                    StreamIndex             = 0
                                    CurrentMulticastAddress = "$($rxStreams[0].MulticastAddress)"
                                    NewMulticastAddress     = "$($rxStreams[0].MulticastAddress)"
                                    SupportsAvMulticast     = $supportsAvMulticast
                                }
                            }

                            $inputs = @($av.Inputs)
                            if ($inputs.Count -gt 0) {
                                $currentInputHdcp = "$($inputs[0].HdcpReceiverCapability)"
                                $currentGlobalEdid = "$($inputs[0].CurrentEdid)"
                            }

                            $supportsInputEdid = $supportsAvSettings -and
                                                 ($inputs.Count -gt 0) -and
                                                 (($edidNames.Count -gt 0) -or -not [string]::IsNullOrWhiteSpace($currentGlobalEdid))

                            for ($i = 0; $i -lt $inputs.Count; $i++) {
                                $inputItem = $inputs[$i]
                                $inputEdidNames = @($inputItem.EdidOptions | Where-Object {
                                    -not [string]::IsNullOrWhiteSpace("$_")
                                } | Sort-Object -Unique)

                                if ($inputEdidNames.Count -eq 0) {
                                    $inputEdidNames = $edidNames
                                }

                                $inputLabel = "$($inputItem.InputName)"
                                if ([string]::IsNullOrWhiteSpace($inputLabel)) {
                                    $inputLabel = "Input $i"
                                }

                                $avInputRows += [pscustomobject]@{
                                    IP               = $ip
                                    InputIndex       = $i
                                    InputLabel       = $inputLabel
                                    PortType         = "$($inputItem.PortType)"
                                    CurrentEdid      = "$($inputItem.CurrentEdid)"
                                    NewEdidName      = "$($inputItem.CurrentEdid)"
                                    EdidNameOptions  = $inputEdidNames
                                    CurrentInputHdcp = "$($inputItem.HdcpReceiverCapability)"
                                    NewInputHdcp     = "$($inputItem.HdcpReceiverCapability)"
                                    SupportsAvSettings = $supportsAvSettings
                                    SupportsEdidEdit = (($inputEdidNames.Count -gt 0) -or -not [string]::IsNullOrWhiteSpace("$($inputItem.CurrentEdid)"))
                                }
                            }

                            $outputs = @($av.Outputs)
                            if ($outputs.Count -gt 0) {
                                $currentOutputHdcp = "$($outputs[0].HdcpTransmitterMode)"
                                $currentOutputResolution = "$($outputs[0].Resolution)"
                            }

                            for ($i = 0; $i -lt $outputs.Count; $i++) {
                                $outputItem = $outputs[$i]
                                $outputLabel = "$($outputItem.OutputName)"
                                if ([string]::IsNullOrWhiteSpace($outputLabel)) {
                                    $outputLabel = "Output $i"
                                }

                                $avOutputRows += [pscustomobject]@{
                                    IP                      = $ip
                                    OutputIndex             = $i
                                    OutputLabel             = $outputLabel
                                    CurrentOutputHdcp       = "$($outputItem.HdcpTransmitterMode)"
                                    NewOutputHdcp           = "$($outputItem.HdcpTransmitterMode)"
                                    CurrentOutputResolution = "$($outputItem.Resolution)"
                                    NewOutputResolution     = "$($outputItem.Resolution)"
                                    SupportsAvSettings      = $supportsAvSettings
                                }
                            }
                        }

                        $q.Enqueue([pscustomobject]@{
                            IP                       = $ip
                            Model                    = $modelText
                            CurrentHostname          = $state.Hostname
                            CurrentDhcp              = $state.EthernetLanDhcp
                            CurrentWifi              = $state.WifiEnabled
                            SupportsNetwork          = if ($null -ne $state.SupportsNetwork) { [bool]$state.SupportsNetwork } else { $true }
                            SupportsIpTable          = [bool]$state.SupportsIpTable
                            HasWifi                  = $state.HasWifi
                            CurrentIP                = $state.EthernetLanIP
                            CurrentSubnet            = $state.EthernetLanSubnet
                            CurrentGateway           = $state.EthernetLanGateway
                            CurrentDns1              = $dns1
                            CurrentDns2              = $dns2
                            CurrentIpId              = $state.CurrentIpId
                            CurrentControlSystemAddr = $state.CurrentControlSystemAddr
                            CurrentRoomId            = $state.CurrentRoomId
                            CurrentDeviceMode        = $state.CurrentDeviceMode
                            SupportsModeChange       = $state.SupportsModeChange
                            AvApiFamily              = $avApiFamily
                            AvApiVersion             = $avApiVersion
                            SupportsAvSettings       = $supportsAvSettings
                            SupportsGlobalEdid       = $supportsGlobalEdid
                            SupportsInputEdid        = $supportsInputEdid
                            SupportsEdidEdit         = ($supportsGlobalEdid -or $supportsInputEdid)
                            EdidNameOptions          = $edidNames
                            EdidNames                = ($edidNames -join '|')
                            SupportsAvMulticast      = $supportsAvMulticast
                            CurrentTransmitMulticast = $txMulticast
                            CurrentReceiveMulticast  = $rxMulticast
                            CurrentInputHdcp         = $currentInputHdcp
                            CurrentOutputHdcp        = $currentOutputHdcp
                            CurrentOutputResolution  = $currentOutputResolution
                            CurrentGlobalEdid        = $currentGlobalEdid
                            AvInputRows              = $avInputRows
                            AvOutputRows             = $avOutputRows
                            MulticastRows            = $multicastRows
                            Detail                   = "OK"
                        })
                    } finally {
                        Disconnect-CrestronDevice -Session $sess
                    }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        IP     = $ip
                        Detail = "ERROR: $($_.Exception.Message)"
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{
                __error = $_.Exception.Message
            })
        } finally {
            $doneRef.Value = $true
        }
    })

    $Script:PerDeviceState.Runspace    = $rs
    $Script:PerDeviceState.PowerShell  = $ps
    $Script:PerDeviceState.AsyncHandle = $ps.BeginInvoke()
    $Script:PerDeviceState.Queue       = $queue
    $Script:PerDeviceState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)

    $timer.Add_Tick({
        $item = $null

        while ($Script:PerDeviceState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Fetch failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }

            $row = $Script:PerDeviceState.RowsByIP[$item.IP]

            if (-not $row) {
                continue
            }

            foreach ($prop in @(
                'CurrentIP',
                'CurrentSubnet',
                'CurrentGateway',
                'CurrentDns1',
                'CurrentDns2',
                'CurrentDeviceMode',
                'SupportsNetwork',
                'SupportsIpTable',
                'SupportsModeChange',
                'AvApiFamily',
                'AvApiVersion',
                'SupportsAvSettings',
                'SupportsGlobalEdid',
                'SupportsInputEdid',
                'SupportsEdidEdit',
                'EdidNameOptions',
                'EdidNames',
                'SupportsAvMulticast',
                'CurrentTransmitMulticast',
                'CurrentReceiveMulticast',
                'CurrentInputHdcp',
                'CurrentOutputHdcp',
                'CurrentOutputResolution',
                'CurrentGlobalEdid',
                'NewHostname',
                'IPMode',
                'NewInputHdcp',
                'NewOutputHdcp',
                'NewOutputResolution',
                'NewGlobalEdidName',
                'NewMulticastAddress',
                'MulticastStreamIndex',
                'DeviceMode',
                'NeedsReboot'
            )) {
                if (-not ($row.PSObject.Properties.Name -contains $prop)) {
                    $defaultValue = switch ($prop) {
                        'CurrentIP'          { '' }
                        'CurrentSubnet'      { '' }
                        'CurrentGateway'     { '' }
                        'CurrentDns1'        { '' }
                        'CurrentDns2'        { '' }
                        'CurrentDeviceMode'  { '' }
                        'SupportsNetwork'    { $false }
                        'SupportsIpTable'    { $false }
                        'SupportsModeChange' { $false }
                        'AvApiFamily'        { '' }
                        'AvApiVersion'       { '' }
                        'SupportsAvSettings' { $false }
                        'SupportsGlobalEdid' { $false }
                        'SupportsInputEdid' { $false }
                        'SupportsEdidEdit' { $false }
                        'EdidNameOptions' { @() }
                        'EdidNames' { '' }
                        'SupportsAvMulticast' { $false }
                        'CurrentTransmitMulticast' { '' }
                        'CurrentReceiveMulticast' { '' }
                        'CurrentInputHdcp' { '' }
                        'CurrentOutputHdcp' { '' }
                        'CurrentOutputResolution' { '' }
                        'CurrentGlobalEdid' { '' }
                        'NewHostname' { 'N/A' }
                        'IPMode' { 'N/A' }
                        'NewInputHdcp' { 'N/A' }
                        'NewOutputHdcp' { 'N/A' }
                        'NewOutputResolution' { 'N/A' }
                        'NewGlobalEdidName' { 'N/A' }
                        'NewMulticastAddress' { 'N/A' }
                        'MulticastStreamIndex' { 'N/A' }
                        'DeviceMode'         { 'N/A' }
                        'NeedsReboot'        { $false }
                    }

                    $row | Add-Member -NotePropertyName $prop -NotePropertyValue $defaultValue -Force
                }
            }

            if ($item.Model) {
                $row.Model                    = $item.Model
                $row.CurrentHostname          = "$($item.CurrentHostname)"
                $row.CurrentDhcp              = $item.CurrentDhcp
                $row.CurrentWifi              = $item.CurrentWifi
                $row.SupportsNetwork          = [bool]$item.SupportsNetwork
                $row.SupportsIpTable          = [bool]$item.SupportsIpTable
                $row.HasWifi                  = [bool]$item.HasWifi
                $row.CurrentIP                = "$($item.CurrentIP)"
                $row.CurrentSubnet            = "$($item.CurrentSubnet)"
                $row.CurrentGateway           = "$($item.CurrentGateway)"
                $row.CurrentDns1              = "$($item.CurrentDns1)"
                $row.CurrentDns2              = "$($item.CurrentDns2)"
                $row.CurrentIpId              = "$($item.CurrentIpId)"
                $row.CurrentControlSystemAddr = "$($item.CurrentControlSystemAddr)"
                $row.CurrentRoomId            = "$($item.CurrentRoomId)"
                $row.CurrentDeviceMode        = "$($item.CurrentDeviceMode)"
                $row.SupportsModeChange       = [bool]$item.SupportsModeChange
                $row.AvApiFamily              = "$($item.AvApiFamily)"
                $row.AvApiVersion             = "$($item.AvApiVersion)"
                $row.SupportsAvSettings       = [bool]$item.SupportsAvSettings
                $row.SupportsGlobalEdid       = [bool]$item.SupportsGlobalEdid
                $row.SupportsInputEdid        = [bool]$item.SupportsInputEdid
                $row.SupportsEdidEdit         = [bool]$item.SupportsEdidEdit
                $row.EdidNameOptions          = @($item.EdidNameOptions)
                $row.EdidNames                = "$($item.EdidNames)"
                $row.SupportsAvMulticast      = [bool]$item.SupportsAvMulticast
                $row.CurrentInputHdcp         = ConvertTo-PerDeviceInputHdcpMode $item.CurrentInputHdcp
                $row.CurrentOutputHdcp        = ConvertTo-PerDeviceOutputHdcpMode $item.CurrentOutputHdcp
                $row.CurrentOutputResolution  = "$($item.CurrentOutputResolution)"
                $row.CurrentGlobalEdid        = "$($item.CurrentGlobalEdid)"

                if ([bool]$item.SupportsNetwork) {
                    $row.NewHostname = "$($item.CurrentHostname)"

                    $row.IPMode = if ([bool]$item.CurrentDhcp) {
                        'DHCP'
                    } else {
                        'Static'
                    }

                    $row.NewIP        = "$($item.CurrentIP)"
                    $row.SubnetMask   = "$($item.CurrentSubnet)"
                    $row.Gateway      = "$($item.CurrentGateway)"
                    $row.PrimaryDns   = "$($item.CurrentDns1)"
                    $row.SecondaryDns = "$($item.CurrentDns2)"
                }
                else {
                    $row.NewHostname  = 'N/A'
                    $row.IPMode       = 'N/A'
                    $row.NewIP        = 'N/A'
                    $row.SubnetMask   = 'N/A'
                    $row.Gateway      = 'N/A'
                    $row.PrimaryDns   = 'N/A'
                    $row.SecondaryDns = 'N/A'
                }

                $row.DeviceMode = if ([bool]$item.SupportsModeChange) {
                    if (-not [string]::IsNullOrWhiteSpace("$($item.CurrentDeviceMode)")) {
                        "$($item.CurrentDeviceMode)"
                    } else {
                        'N/A'
                    }
                } else {
                    'N/A'
                }

                if (-not [bool]$item.SupportsAvSettings) {
                    $row.CurrentInputHdcp        = 'N/A'
                    $row.CurrentOutputHdcp       = 'N/A'
                    $row.CurrentOutputResolution = 'N/A'
                    $row.CurrentGlobalEdid       = 'N/A'
                    $row.SupportsInputEdid       = $false
                    $row.SupportsEdidEdit        = $false
                    $row.NewInputHdcp            = 'N/A'
                    $row.NewOutputHdcp           = 'N/A'
                    $row.NewOutputResolution     = 'N/A'
                    $row.NewGlobalEdidName       = 'N/A'
                }
                else {
                    $row.CurrentInputHdcp        = ConvertTo-PerDeviceInputHdcpMode $item.CurrentInputHdcp
                    $row.CurrentOutputHdcp       = ConvertTo-PerDeviceOutputHdcpMode $item.CurrentOutputHdcp
                    $row.CurrentOutputResolution = "$($item.CurrentOutputResolution)"
                    $row.CurrentGlobalEdid = "$($item.CurrentGlobalEdid)"
                    if (-not $row.SupportsEdidEdit) {
                        $row.SupportsEdidEdit = [bool]$row.SupportsGlobalEdid -or [bool]$row.SupportsInputEdid
                    }
                    $row.NewInputHdcp = if (Test-PerDeviceValue $row.CurrentInputHdcp) {
                        "$($row.CurrentInputHdcp)"
                    } else {
                        'N/A'
                    }
                    $row.NewOutputHdcp = if (Test-PerDeviceValue $row.CurrentOutputHdcp) {
                        "$($row.CurrentOutputHdcp)"
                    } else {
                        'N/A'
                    }
                    $row.NewOutputResolution = if (Test-PerDeviceValue $row.CurrentOutputResolution) {
                        "$($row.CurrentOutputResolution)"
                    } else {
                        'N/A'
                    }
                    $row.NewGlobalEdidName = if (Test-PerDeviceValue $row.CurrentGlobalEdid) {
                        "$($row.CurrentGlobalEdid)"
                    } else {
                        ''
                    }
                }

                if (-not [bool]$item.SupportsAvMulticast) {
                    $row.CurrentTransmitMulticast = 'N/A'
                    $row.CurrentReceiveMulticast  = 'N/A'
                    $row.NewMulticastAddress      = 'N/A'
                    $row.MulticastStreamIndex     = 'N/A'
                }
                else {
                    $row.CurrentTransmitMulticast = "$($item.CurrentTransmitMulticast)"
                    $row.CurrentReceiveMulticast  = "$($item.CurrentReceiveMulticast)"
                    $row.NewMulticastAddress      = Get-PerDeviceCurrentMulticastAddress $row
                    $row.MulticastStreamIndex     = '0'
                }

                Remove-PerDeviceSectionRowsByIP -Collection $Script:PerDeviceState.AvInputRows -IP $item.IP
                Remove-PerDeviceSectionRowsByIP -Collection $Script:PerDeviceState.AvOutputRows -IP $item.IP
                Remove-PerDeviceSectionRowsByIP -Collection $Script:PerDeviceState.MulticastRows -IP $item.IP

                foreach ($inputRow in @($item.AvInputRows)) {
                    $currentInputHdcp = ConvertTo-PerDeviceInputHdcpMode $inputRow.CurrentInputHdcp
                    $newInputHdcp = if (Test-PerDeviceValue $currentInputHdcp) { "$currentInputHdcp" } else { 'N/A' }
                    $currentEdid = "$($inputRow.CurrentEdid)"

                    [void]$Script:PerDeviceState.AvInputRows.Add([pscustomobject]@{
                        IP                 = "$($inputRow.IP)"
                        InputIndex         = [int]$inputRow.InputIndex
                        InputLabel         = "$($inputRow.InputLabel)"
                        PortType           = "$($inputRow.PortType)"
                        CurrentEdid        = $currentEdid
                        NewEdidName        = if (Test-PerDeviceValue $currentEdid) { $currentEdid } else { '' }
                        EdidNameOptions    = @($inputRow.EdidNameOptions)
                        CurrentInputHdcp   = $currentInputHdcp
                        NewInputHdcp       = $newInputHdcp
                        SupportsAvSettings = [bool]$inputRow.SupportsAvSettings
                        SupportsEdidEdit   = [bool]$inputRow.SupportsEdidEdit
                    })
                }

                foreach ($outputRow in @($item.AvOutputRows)) {
                    $currentOutputHdcp = ConvertTo-PerDeviceOutputHdcpMode $outputRow.CurrentOutputHdcp
                    $newOutputHdcp = if (Test-PerDeviceValue $currentOutputHdcp) { "$currentOutputHdcp" } else { 'N/A' }
                    $currentOutputResolution = "$($outputRow.CurrentOutputResolution)"

                    [void]$Script:PerDeviceState.AvOutputRows.Add([pscustomobject]@{
                        IP                      = "$($outputRow.IP)"
                        OutputIndex             = [int]$outputRow.OutputIndex
                        OutputLabel             = "$($outputRow.OutputLabel)"
                        CurrentOutputHdcp       = $currentOutputHdcp
                        NewOutputHdcp           = $newOutputHdcp
                        CurrentOutputResolution = $currentOutputResolution
                        NewOutputResolution     = if (Test-PerDeviceValue $currentOutputResolution) { $currentOutputResolution } else { 'N/A' }
                        SupportsAvSettings      = [bool]$outputRow.SupportsAvSettings
                    })
                }

                foreach ($mcRow in @($item.MulticastRows)) {
                    $currentMc = "$($mcRow.CurrentMulticastAddress)"

                    [void]$Script:PerDeviceState.MulticastRows.Add([pscustomobject]@{
                        IP                      = "$($mcRow.IP)"
                        Direction               = "$($mcRow.Direction)"
                        StreamIndex             = 0
                        CurrentMulticastAddress = $currentMc
                        NewMulticastAddress     = if (Test-PerDeviceValue $currentMc) { $currentMc } else { 'N/A' }
                        SupportsAvMulticast     = [bool]$mcRow.SupportsAvMulticast
                    })
                }

                if (-not [bool]$item.HasWifi) {
                    $row.DisableWifi = $false
                }

                if ([bool]$item.SupportsIpTable) {
                    $row.NewIpId              = "$($item.CurrentIpId)"
                    $row.NewControlSystemAddr = "$($item.CurrentControlSystemAddr)"
                }
                else {
                    $row.NewIpId              = 'N/A'
                    $row.NewControlSystemAddr = 'N/A'
                }

                if (-not $row.Status) {
                    $row.Status = ''
                }
            }

            $row.Detail = $item.Detail
        }

        $Script:UI.PerDeviceGrid.Items.Refresh()
        $Script:UI.PerDeviceAvInputGrid.Items.Refresh()
        $Script:UI.PerDeviceAvOutputGrid.Items.Refresh()
        $Script:UI.PerDeviceMulticastGrid.Items.Refresh()
        Update-PerDeviceSummary

        if ($Script:PerDeviceState.DoneRef.Value -and $Script:PerDeviceState.Queue.IsEmpty) {
            Stop-PerDeviceRunspace
            Set-PerDeviceControls $false
            $Script:UI.PerDeviceProgressText.Text = "Fetch complete."
            Update-Status "Per-device state fetch complete."
        }
    })

    $timer.Start()
    $Script:PerDeviceState.Timer = $timer
}

# Validate a row before apply
function Test-PerDeviceRow ($row) {
    if ((Test-PerDeviceValue $row.NewHostname) -and -not [bool]$row.SupportsNetwork) {
        return "Network/hostname settings selected, but this device does not expose network settings"
    }

    if ((Test-PerDeviceValue $row.NewHostname) -and ($row.NewHostname -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')) {
        return "Invalid hostname '$($row.NewHostname)'"
    }
    if (($row.IPMode -in 'DHCP','Static') -and -not [bool]$row.SupportsNetwork) {
        return "IP address settings selected, but this device does not expose network settings"
    }

    if ($row.IPMode -eq 'Static') {
        if (-not [bool]$row.SupportsNetwork) {
            return "IP address settings selected, but this device does not expose network settings"
        }

        $ipPattern = '^(\d{1,3}\.){3}\d{1,3}$'
        if ($row.NewIP      -notmatch $ipPattern) { return "Invalid IP Address" }
        if ($row.SubnetMask -notmatch $ipPattern) { return "Invalid SubnetMask" }
        if ($row.Gateway    -notmatch $ipPattern) { return "Invalid Gateway" }
        if ((Test-PerDeviceValue $row.PrimaryDns) -and $row.PrimaryDns -notmatch $ipPattern) { return "Invalid DNS1" }
        if ((Test-PerDeviceValue $row.SecondaryDns) -and $row.SecondaryDns -notmatch $ipPattern) { return "Invalid DNS2" }
    }
    if ($row.DisableWifi -and -not $row.HasWifi) {
        return "This device has no WiFi adapter (uncheck 'WiFi Off')"
    }
    # IP-table validation: if any of the three IP-table fields are set, require all three
    $ipAny = (Test-PerDeviceValue $row.NewIpId) -or (Test-PerDeviceValue $row.NewControlSystemAddr)
    if ($ipAny) {
        if (-not [bool]$row.SupportsIpTable) { return "Control System fields selected, but this device does not expose IP table settings" }
        if (-not (Test-PerDeviceValue $row.NewIpId)) { return "IPID is required when setting Control System fields" }
        if ($row.NewIpId -notmatch '^[0-9A-Fa-f]{1,2}$') { return "IPID '$($row.NewIpId)' must be 1-2 hex digits (1..FE)" }
        $ipIdInt = [Convert]::ToInt32($row.NewIpId, 16)
        if ($ipIdInt -lt 1 -or $ipIdInt -gt 254) { return "IPID '$($row.NewIpId)' is out of range (1..FE)" }
        if (-not (Test-PerDeviceValue $row.NewControlSystemAddr)) { return "Control System IP is required when setting Control System fields" }
        $addr = $row.NewControlSystemAddr
        $isIpv4 = $addr -match '^(\d{1,3}\.){3}\d{1,3}$'
        $isHost = $addr -match '^[A-Za-z0-9]([A-Za-z0-9\-\.]{0,253}[A-Za-z0-9])?$'
        if (-not ($isIpv4 -or $isHost)) { return "Control System IP '$addr' is not a valid IPv4 or hostname" }
    }
    if ($row.DeviceMode -in 'Transmitter','Receiver') {
        if (-not $row.SupportsModeChange) {
            return "Device mode change selected, but this device does not expose DeviceSpecific.DeviceMode"
        }
    }

    return $null
}

function Test-PerDeviceAvInputRow ($row) {
    if ((Test-PerDeviceInputHdcpMode $row.NewInputHdcp) -and -not [bool]$row.SupportsAvSettings) {
        return "Input HDCP selected, but this input does not expose AV settings"
    }

    if ((Test-PerDeviceValue $row.NewEdidName) -and "$($row.NewEdidName)" -ne "$($row.CurrentEdid)" -and -not [bool]$row.SupportsEdidEdit) {
        return "EDID selected, but this input does not expose editable EDID settings"
    }

    return $null
}

function Test-PerDeviceAvOutputRow ($row) {
    $hdcpSelected = $row.NewOutputHdcp -in 'Auto','FollowInput','ForceHighest','NeverAuthenticate'
    $resolutionSelected = Test-PerDeviceValue $row.NewOutputResolution

    if (($hdcpSelected -or $resolutionSelected) -and -not [bool]$row.SupportsAvSettings) {
        return "Output AV settings selected, but this output does not expose AV settings"
    }

    return $null
}

function Test-PerDeviceMulticastRow ($row) {
    if (-not (Test-PerDeviceMulticastChanged $row)) {
        return $null
    }

    if (-not [bool]$row.SupportsAvMulticast) {
        return "Multicast selected, but this device does not expose stream multicast settings"
    }

    if ("$($row.NewMulticastAddress)" -notmatch '^239\.(\d{1,3}\.){2}\d{1,3}$') {
        return "Multicast address '$($row.NewMulticastAddress)' must be in the 239.x.x.x range"
    }

    foreach ($octet in ("$($row.NewMulticastAddress)" -split '\.')) {
        $n = [int]$octet
        if ($n -lt 0 -or $n -gt 255) {
            return "Multicast address '$($row.NewMulticastAddress)' has an octet outside 0-255"
        }
    }

    return $null
}

function Start-PerDeviceApply {
    if ($Script:PerDeviceState.IsRunning) { return }

    # Find rows with any change
    # Only treat IPID/CS-IP as a "change" if the new value differs from current
    # (otherwise every fetched row would trigger a pointless rewrite).
    $rowsToApply = @($Script:PerDeviceState.Rows | Where-Object {
        $hostnameChanged = (Test-PerDeviceValue $_.NewHostname) -and
                        "$($_.NewHostname)" -ne "$($_.CurrentHostname)"

        $ipModeChanged = $false
        if ($_.IPMode -in 'DHCP','Static') {
            $currentIpMode = if ([bool]$_.CurrentDhcp) {
                'DHCP'
            } else {
                'Static'
            }

            $ipModeChanged = $_.IPMode -ne $currentIpMode
        }

        $deviceModeChanged = $false
        if ($_.DeviceMode -in 'Transmitter','Receiver') {
            $deviceModeChanged = $_.DeviceMode -ne $_.CurrentDeviceMode
        }

        $ipTableChanged = ((Test-PerDeviceValue $_.NewIpId) -and "$($_.NewIpId)" -ne "$($_.CurrentIpId)") -or
                        ((Test-PerDeviceValue $_.NewControlSystemAddr) -and "$($_.NewControlSystemAddr)" -ne "$($_.CurrentControlSystemAddr)")

        $networkValueChanged = ((Test-PerDeviceValue $_.NewIP) -and "$($_.NewIP)" -ne "$($_.CurrentIP)") -or
                            ((Test-PerDeviceValue $_.SubnetMask) -and "$($_.SubnetMask)" -ne "$($_.CurrentSubnet)") -or
                            ((Test-PerDeviceValue $_.Gateway) -and "$($_.Gateway)" -ne "$($_.CurrentGateway)") -or
                            ((Test-PerDeviceValue $_.PrimaryDns) -and "$($_.PrimaryDns)" -ne "$($_.CurrentDns1)") -or
                            ((Test-PerDeviceValue $_.SecondaryDns) -and "$($_.SecondaryDns)" -ne "$($_.CurrentDns2)")

        $hostnameChanged -or
        $ipModeChanged -or
        $deviceModeChanged -or
        $ipTableChanged -or
        $networkValueChanged -or
        $_.DisableWifi
    })

    $inputRowsToApply = @($Script:PerDeviceState.AvInputRows | Where-Object { Test-PerDeviceAvInputChanged $_ })
    $outputRowsToApply = @($Script:PerDeviceState.AvOutputRows | Where-Object { Test-PerDeviceAvOutputChanged $_ })
    $multicastRowsToApply = @($Script:PerDeviceState.MulticastRows | Where-Object { Test-PerDeviceMulticastChanged $_ })
    $applyIps = @()
    $applyIps += @($rowsToApply | ForEach-Object { "$($_.IP)" })
    $applyIps += @($inputRowsToApply | ForEach-Object { "$($_.IP)" })
    $applyIps += @($outputRowsToApply | ForEach-Object { "$($_.IP)" })
    $applyIps += @($multicastRowsToApply | ForEach-Object { "$($_.IP)" })
    $applyIps = @($applyIps |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    if ($applyIps.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No rows have any pending changes.", "Nothing to apply", 'OK', 'Warning') | Out-Null
        return
    }

    $rowsForApply = @($applyIps | ForEach-Object {
        $Script:PerDeviceState.RowsByIP[$_]
    } | Where-Object { $_ })

    # Validate
    $errors = @()
    foreach ($r in $rowsToApply) {
        $err = Test-PerDeviceRow $r
        if ($err) { $errors += "$($r.IP): $err" }
    }
    foreach ($r in $inputRowsToApply) {
        $err = Test-PerDeviceAvInputRow $r
        if ($err) { $errors += "$($r.IP) $($r.InputLabel): $err" }
    }
    foreach ($r in $outputRowsToApply) {
        $err = Test-PerDeviceAvOutputRow $r
        if ($err) { $errors += "$($r.IP) $($r.OutputLabel): $err" }
    }
    foreach ($r in $multicastRowsToApply) {
        $err = Test-PerDeviceMulticastRow $r
        if ($err) { $errors += "$($r.IP) $($r.Direction): $err" }
    }

    if ($errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show("Validation failed:`n`n$($errors -join "`n")", "Fix errors first", 'OK', 'Error') | Out-Null
        return
    }

    $cred = Get-CachedCredential
    if (-not $cred) {
        Update-Status 'Apply cancelled (no credentials).'
        return
    }

    # WiFi safety check — anyone reaching the device via WiFi about to lose it?
    $wifiWarnings = @()
    foreach ($r in $rowsToApply) {
        if ($r.DisableWifi -and $r.CurrentWifi -and $r.CurrentWifi -eq $true) {
            # We don't know exactly which adapter the GUI is using to reach the device,
            # but if WiFi adapter is enabled AND we're about to disable it, flag it.
            $wifiWarnings += $r.IP
        }
    }

    if ($wifiWarnings.Count -gt 0) {
        $msg = "WiFi will be disabled on these device(s):`n`n$($wifiWarnings -join "`n")`n`nIf any of these are reached over WiFi, you will lose connection. Continue?"
        $ans = [System.Windows.MessageBox]::Show($msg, "WiFi disable warning", 'YesNo', 'Warning')
        if ($ans -ne 'Yes') {
            Update-Status 'Apply cancelled.'
            return
        }
    }

    $msg = "Apply changes to $($applyIps.Count) device(s) as '$($cred.UserName)'?`n`nIP changes are fire-and-forget — Success means the device acknowledged the change, not that it came back on the new IP."
    $ans = [System.Windows.MessageBox]::Show($msg, "Confirm per-device apply", 'YesNo', 'Warning')
    if ($ans -ne 'Yes') {
        Update-Status 'Apply cancelled.'
        return
    }

    foreach ($r in $rowsForApply) {
        $r.Status      = 'Pending'
        $r.Detail      = ''
        $r.NeedsReboot = $false
        $r.Timestamp   = ''
    }

    $Script:UI.PerDeviceGrid.Items.Refresh()
    $Script:UI.PerDeviceProgressText.Text = "Applying to $($applyIps.Count) device(s)..."
    Set-PerDeviceControls $true
    Update-Status "Applying per-device changes to $($applyIps.Count) device(s)..."

    # Serialize rows as plain hashtables so they cross the runspace boundary
    $rowData = $rowsForApply | ForEach-Object {
        $rowIp = "$($_.IP)"
        @{
            IP                       = $_.IP
            NewHostname              = $_.NewHostname
            CurrentHostname          = $_.CurrentHostname
            IPMode                   = $_.IPMode
            CurrentDhcp              = $_.CurrentDhcp
            SupportsNetwork          = [bool]$_.SupportsNetwork
            DeviceMode               = $_.DeviceMode
            SupportsModeChange       = [bool]$_.SupportsModeChange
            CurrentDeviceMode        = $_.CurrentDeviceMode
            SupportsAvSettings       = [bool]$_.SupportsAvSettings
            SupportsGlobalEdid       = [bool]$_.SupportsGlobalEdid
            SupportsInputEdid        = [bool]$_.SupportsInputEdid
            SupportsEdidEdit         = [bool]$_.SupportsEdidEdit
            NewInputHdcp             = $_.NewInputHdcp
            CurrentInputHdcp         = $_.CurrentInputHdcp
            NewOutputHdcp            = $_.NewOutputHdcp
            CurrentOutputHdcp        = $_.CurrentOutputHdcp
            NewOutputResolution      = $_.NewOutputResolution
            CurrentOutputResolution  = $_.CurrentOutputResolution
            NewGlobalEdidName        = $_.NewGlobalEdidName
            CurrentGlobalEdid        = $_.CurrentGlobalEdid
            SupportsAvMulticast      = [bool]$_.SupportsAvMulticast
            CurrentTransmitMulticast = $_.CurrentTransmitMulticast
            CurrentReceiveMulticast  = $_.CurrentReceiveMulticast
            NewMulticastAddress      = $_.NewMulticastAddress
            MulticastStreamIndex     = $_.MulticastStreamIndex
            NewIP                    = $_.NewIP
            CurrentIP                = $_.CurrentIP
            SubnetMask               = $_.SubnetMask
            CurrentSubnet            = $_.CurrentSubnet
            Gateway                  = $_.Gateway
            CurrentGateway           = $_.CurrentGateway
            PrimaryDns               = $_.PrimaryDns
            CurrentDns1              = $_.CurrentDns1
            SecondaryDns             = $_.SecondaryDns
            CurrentDns2              = $_.CurrentDns2
            DisableWifi              = [bool]$_.DisableWifi
            NewIpId                  = $_.NewIpId
            NewControlSystemAddr     = $_.NewControlSystemAddr
            SupportsIpTable          = [bool]$_.SupportsIpTable
            CurrentIpId              = $_.CurrentIpId
            CurrentControlSystemAddr = $_.CurrentControlSystemAddr
            AvInputRows              = @($inputRowsToApply | Where-Object { "$($_.IP)" -eq $rowIp } | ForEach-Object {
                @{
                    IP                 = $_.IP
                    InputIndex         = [int]$_.InputIndex
                    InputLabel         = $_.InputLabel
                    CurrentEdid        = $_.CurrentEdid
                    NewEdidName        = $_.NewEdidName
                    CurrentInputHdcp   = $_.CurrentInputHdcp
                    NewInputHdcp       = $_.NewInputHdcp
                    SupportsAvSettings = [bool]$_.SupportsAvSettings
                    SupportsEdidEdit   = [bool]$_.SupportsEdidEdit
                }
            })
            AvOutputRows             = @($outputRowsToApply | Where-Object { "$($_.IP)" -eq $rowIp } | ForEach-Object {
                @{
                    IP                      = $_.IP
                    OutputIndex             = [int]$_.OutputIndex
                    OutputLabel             = $_.OutputLabel
                    CurrentOutputHdcp       = $_.CurrentOutputHdcp
                    NewOutputHdcp           = $_.NewOutputHdcp
                    CurrentOutputResolution = $_.CurrentOutputResolution
                    NewOutputResolution     = $_.NewOutputResolution
                    SupportsAvSettings      = [bool]$_.SupportsAvSettings
                }
            })
            MulticastRows            = @($multicastRowsToApply | Where-Object { "$($_.IP)" -eq $rowIp } | ForEach-Object {
                @{
                    IP                      = $_.IP
                    Direction               = $_.Direction
                    StreamIndex             = 0
                    CurrentMulticastAddress = $_.CurrentMulticastAddress
                    NewMulticastAddress     = $_.NewMulticastAddress
                    SupportsAvMulticast     = [bool]$_.SupportsAvMulticast
                }
            })
        }
    }

    $modManifest = (Get-Module CrestronAdminBootstrap).Path
    if (-not $modManifest) {
        $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap | Sort-Object Version -Descending | Select-Object -First 1).Path
    }

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',    $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',  $doneRef)
    $rs.SessionStateProxy.SetVariable('rows',     $rowData)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            $rows | ForEach-Object -ThrottleLimit 16 -Parallel {
                $row = $_
                $q   = $using:queue
                $u   = $using:userName
                $p   = $using:userPass
                $mp  = $using:manifest

                $q.Enqueue([pscustomobject]@{
                    __progress = $true
                    IP         = $row.IP
                    Status     = 'Working'
                })

                try {
                    if (-not $mp -or -not (Test-Path $mp)) {
                        throw "Module manifest path missing: '$mp'"
                    }

                    Import-Module $mp -Force -ErrorAction Stop

                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $row.IP -Credential $cred

                    $stepResults = @()
                    $allOk = $true
                    $needsReboot = $false

                    function Test-PerDeviceValue {
                        param($Value)

                        $text = "$Value"
                        return (-not [string]::IsNullOrWhiteSpace($text)) -and ($text -ne 'N/A')
                    }

                    function Test-PerDeviceInputHdcpMode {
                        param($Value)

                        return "$Value" -in @(
                            'Auto',
                            'HDCP 1.4',
                            'HDCP 2.x',
                            'Never Authenticate',
                            'Disabled',
                            'Enabled',
                            'HDCP 1.x',
                            'HDCP 2.0',
                            'HDCP 2.2',
                            'NeverAuthenticate'
                        )
                    }

                    function Test-ResultNeedsReboot {
                        param(
                            $Result
                        )

                        if (-not $Result) {
                            return $false
                        }

                        if ($Result.PSObject.Properties.Name -contains 'NeedsReboot') {
                            if ([bool]$Result.NeedsReboot) {
                                return $true
                            }
                        }

                        if ($Result.PSObject.Properties.Name -contains 'SectionResults' -and $Result.SectionResults) {
                            foreach ($sr in @($Result.SectionResults)) {
                                if ($sr.PSObject.Properties.Name -contains 'StatusId') {
                                    try {
                                        if ([int]$sr.StatusId -eq 1) {
                                            return $true
                                        }
                                    }
                                    catch { }
                                }

                                if ("$($sr.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                                    return $true
                                }

                                if ("$($sr.Response)" -match '(?i)reboot|restart|power cycle') {
                                    return $true
                                }
                            }
                        }

                        if ("$($Result.StatusInfo)" -match '(?i)reboot|restart|power cycle') {
                            return $true
                        }

                        if ("$($Result.Response)" -match '(?i)reboot|restart|power cycle') {
                            return $true
                        }

                        return $false
                    }

                    try {
                        if ((Test-PerDeviceValue $row.NewHostname) -and "$($row.NewHostname)" -ne "$($row.CurrentHostname)") {
                            if (-not [bool]$row.SupportsNetwork) {
                                $stepResults += "Hostname=skipped; unsupported"
                                $allOk = $false
                            }
                            else {
                                $r1 = Set-CrestronHostname -Session $sess -Hostname $row.NewHostname
                                $stepResults += "Hostname=$(if($r1.Success){'OK'}else{$r1.Status})"

                                if (Test-ResultNeedsReboot $r1) {
                                    $needsReboot = $true
                                }

                                if (-not $r1.Success) {
                                    $allOk = $false
                                }
                            }
                        }

                        $ipChanged = ((Test-PerDeviceValue $row.NewIpId) -and $row.NewIpId -ne $row.CurrentIpId) -or
                                     ((Test-PerDeviceValue $row.NewControlSystemAddr) -and $row.NewControlSystemAddr -ne $row.CurrentControlSystemAddr)

                        if ($ipChanged) {
                            try {
                                if (-not [bool]$row.SupportsIpTable) {
                                    $stepResults += "IpTable=skipped; unsupported"
                                    $allOk = $false
                                }
                                else {
                                    $r3 = Set-CrestronIpTable -Session $sess `
                                        -IpId $row.NewIpId `
                                        -ControlSystemAddress $row.NewControlSystemAddr `
                                        -EncryptConnection $false

                                    $stepResults += "IpTable=$(if($r3.Success){'OK'}else{$r3.Status})"

                                    if (Test-ResultNeedsReboot $r3) {
                                        $needsReboot = $true
                                    }

                                    if (-not $r3.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "IpTable=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        $currentIpMode = if ([bool]$row.CurrentDhcp) {
                            'DHCP'
                        } else {
                            'Static'
                        }

                        $ipModeChanged = ($row.IPMode -in 'DHCP','Static') -and
                                         ($row.IPMode -ne $currentIpMode)

                        $networkValueChanged = ((Test-PerDeviceValue $row.NewIP) -and "$($row.NewIP)" -ne "$($row.CurrentIP)") -or
                                               ((Test-PerDeviceValue $row.SubnetMask) -and "$($row.SubnetMask)" -ne "$($row.CurrentSubnet)") -or
                                               ((Test-PerDeviceValue $row.Gateway) -and "$($row.Gateway)" -ne "$($row.CurrentGateway)") -or
                                               ((Test-PerDeviceValue $row.PrimaryDns) -and "$($row.PrimaryDns)" -ne "$($row.CurrentDns1)") -or
                                               ((Test-PerDeviceValue $row.SecondaryDns) -and "$($row.SecondaryDns)" -ne "$($row.CurrentDns2)")
                        if ($ipModeChanged -or $networkValueChanged -or $row.DisableWifi) {
                            if (-not [bool]$row.SupportsNetwork) {
                                $stepResults += "Network=skipped; unsupported"
                                $allOk = $false
                            }
                            else {
                                $netArgs = @{
                                    Session = $sess
                                    IPMode  = $row.IPMode
                                }

                                if ($row.IPMode -eq 'Static') {
                                    $netArgs.NewIP      = $row.NewIP
                                    $netArgs.SubnetMask = $row.SubnetMask
                                    $netArgs.Gateway    = $row.Gateway

                                    if (Test-PerDeviceValue $row.PrimaryDns) {
                                        $netArgs.PrimaryDns = $row.PrimaryDns
                                    }

                                    if (Test-PerDeviceValue $row.SecondaryDns) {
                                        $netArgs.SecondaryDns = $row.SecondaryDns
                                    }
                                }

                                if ($row.DisableWifi) {
                                    $netArgs.DisableWifi = $true
                                }

                                $r2 = Set-CrestronNetwork @netArgs
                                $stepResults += "Network=$(if($r2.Success){'OK'}else{$r2.Status})"

                                if (Test-ResultNeedsReboot $r2) {
                                    $needsReboot = $true
                                }

                                if (-not $r2.Success) {
                                    $allOk = $false
                                }
                            }
                        } elseif ($row.DisableWifi) {
                            # WiFi-off only, no IP change. Need a payload — use IPMode=Keep semantics:
                            # we'll send a DHCP-mode write keeping it on its current setting only
                            # if no IP change. Simplest: route through Set-CrestronNetwork with the
                            # current DHCP setting preserved. We don't have current state here, so
                            # fire IPMode=DHCP which is a no-op for already-DHCP devices but a switch
                            # otherwise. To be safe, require IPMode change OR no WiFi-only ops.
                            $stepResults += "WifiOnly=skipped (set IPMode to apply WiFi-off)"
                            $allOk = $false
                        }

                        if ($row.DeviceMode -in 'Transmitter','Receiver') {
                            try {
                                if (-not [bool]$row.SupportsModeChange) {
                                    $stepResults += "DeviceMode=skipped; unsupported"
                                    $allOk = $false
                                }
                                elseif ($row.CurrentDeviceMode -eq $row.DeviceMode) {
                                    $stepResults += "DeviceMode=already $($row.DeviceMode)"
                                }
                                else {
                                    $rMode = Set-CrestronDeviceMode -Session $sess -Mode $row.DeviceMode
                                    $stepResults += "DeviceMode=$(if($rMode.Success){'OK'}else{$rMode.Status}) -> $($row.DeviceMode)"

                                    if ($rMode.NeedsReboot) {
                                        $needsReboot = $true
                                    }

                                    if (-not $rMode.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "DeviceMode=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        if (Test-PerDeviceInputHdcpMode $row.NewInputHdcp) {
                            try {
                                if (-not [bool]$row.SupportsAvSettings) {
                                    $stepResults += "InputHdcp=skipped; unsupported"
                                    $allOk = $false
                                }
                                elseif ("$($row.NewInputHdcp)" -eq "$($row.CurrentInputHdcp)") {
                                    $stepResults += "InputHdcp=already $($row.NewInputHdcp)"
                                }
                                else {
                                    $rInHdcp = Set-CrestronInputHdcp -Session $sess -Mode $row.NewInputHdcp
                                    $stepResults += "InputHdcp=$(if($rInHdcp.Success){'OK'}else{$rInHdcp.Status}) -> $($row.NewInputHdcp)"

                                    if (Test-ResultNeedsReboot $rInHdcp) {
                                        $needsReboot = $true
                                    }

                                    if (-not $rInHdcp.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "InputHdcp=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        if ($row.NewOutputHdcp -in 'Auto','FollowInput','ForceHighest','NeverAuthenticate') {
                            try {
                                if (-not [bool]$row.SupportsAvSettings) {
                                    $stepResults += "OutputHdcp=skipped; unsupported"
                                    $allOk = $false
                                }
                                elseif ("$($row.NewOutputHdcp)" -eq "$($row.CurrentOutputHdcp)") {
                                    $stepResults += "OutputHdcp=already $($row.NewOutputHdcp)"
                                }
                                else {
                                    $rOutHdcp = Set-CrestronOutputHdcp -Session $sess -Mode $row.NewOutputHdcp
                                    $stepResults += "OutputHdcp=$(if($rOutHdcp.Success){'OK'}else{$rOutHdcp.Status}) -> $($row.NewOutputHdcp)"

                                    if (Test-ResultNeedsReboot $rOutHdcp) {
                                        $needsReboot = $true
                                    }

                                    if (-not $rOutHdcp.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "OutputHdcp=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        if (Test-PerDeviceValue $row.NewOutputResolution) {
                            try {
                                if (-not [bool]$row.SupportsAvSettings) {
                                    $stepResults += "OutputResolution=skipped; unsupported"
                                    $allOk = $false
                                }
                                elseif ("$($row.NewOutputResolution)" -eq "$($row.CurrentOutputResolution)") {
                                    $stepResults += "OutputResolution=already $($row.NewOutputResolution)"
                                }
                                else {
                                    $rOutRes = Set-CrestronOutputResolution -Session $sess -Resolution $row.NewOutputResolution
                                    $stepResults += "OutputResolution=$(if($rOutRes.Success){'OK'}else{$rOutRes.Status}) -> $($row.NewOutputResolution)"

                                    if (Test-ResultNeedsReboot $rOutRes) {
                                        $needsReboot = $true
                                    }

                                    if (-not $rOutRes.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "OutputResolution=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        if ((Test-PerDeviceValue $row.NewGlobalEdidName) -and "$($row.NewGlobalEdidName)" -ne "$($row.CurrentGlobalEdid)") {
                            try {
                                if (-not [bool]$row.SupportsEdidEdit) {
                                    $stepResults += "EDID=skipped; unsupported"
                                    $allOk = $false
                                }
                                else {
                                    $rEdid = Set-CrestronInputEdid `
                                        -Session $sess `
                                        -EdidName $row.NewGlobalEdidName `
                                        -EdidType 'System'

                                    $stepResults += "EDID=$(if($rEdid.Success){'OK'}else{$rEdid.Status}) -> $($row.NewGlobalEdidName)"

                                    if (Test-ResultNeedsReboot $rEdid) {
                                        $needsReboot = $true
                                    }

                                    if (-not $rEdid.Success) {
                                        $allOk = $false
                                    }
                                }
                            } catch {
                                $stepResults += "EDID=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        foreach ($inputRow in @($row.AvInputRows)) {
                            if ((Test-PerDeviceInputHdcpMode $inputRow.NewInputHdcp) -and "$($inputRow.NewInputHdcp)" -ne "$($inputRow.CurrentInputHdcp)") {
                                try {
                                    if (-not [bool]$inputRow.SupportsAvSettings) {
                                        $stepResults += "InputHdcp[$($inputRow.InputIndex)]=skipped; unsupported"
                                        $allOk = $false
                                    }
                                    else {
                                        $rInHdcp = Set-CrestronInputHdcp `
                                            -Session $sess `
                                            -Mode $inputRow.NewInputHdcp `
                                            -InputIndex ([int]$inputRow.InputIndex)

                                        $stepResults += "InputHdcp[$($inputRow.InputIndex)]=$(if($rInHdcp.Success){'OK'}else{$rInHdcp.Status}) -> $($inputRow.NewInputHdcp)"

                                        if (Test-ResultNeedsReboot $rInHdcp) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rInHdcp.Success) {
                                            $allOk = $false
                                        }
                                    }
                                } catch {
                                    $stepResults += "InputHdcp[$($inputRow.InputIndex)]=ERR: $($_.Exception.Message)"
                                    $allOk = $false
                                }
                            }

                            if ((Test-PerDeviceValue $inputRow.NewEdidName) -and "$($inputRow.NewEdidName)" -ne "$($inputRow.CurrentEdid)") {
                                try {
                                    if (-not [bool]$inputRow.SupportsEdidEdit) {
                                        $stepResults += "EDID[$($inputRow.InputIndex)]=skipped; unsupported"
                                        $allOk = $false
                                    }
                                    else {
                                        $rEdid = Set-CrestronInputEdid `
                                            -Session $sess `
                                            -EdidName $inputRow.NewEdidName `
                                            -EdidType 'System' `
                                            -InputIndex ([int]$inputRow.InputIndex)

                                        $stepResults += "EDID[$($inputRow.InputIndex)]=$(if($rEdid.Success){'OK'}else{$rEdid.Status}) -> $($inputRow.NewEdidName)"

                                        if (Test-ResultNeedsReboot $rEdid) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rEdid.Success) {
                                            $allOk = $false
                                        }
                                    }
                                } catch {
                                    $stepResults += "EDID[$($inputRow.InputIndex)]=ERR: $($_.Exception.Message)"
                                    $allOk = $false
                                }
                            }
                        }

                        foreach ($outputRow in @($row.AvOutputRows)) {
                            if (($outputRow.NewOutputHdcp -in 'Auto','FollowInput','ForceHighest','NeverAuthenticate') -and "$($outputRow.NewOutputHdcp)" -ne "$($outputRow.CurrentOutputHdcp)") {
                                try {
                                    if (-not [bool]$outputRow.SupportsAvSettings) {
                                        $stepResults += "OutputHdcp[$($outputRow.OutputIndex)]=skipped; unsupported"
                                        $allOk = $false
                                    }
                                    else {
                                        $rOutHdcp = Set-CrestronOutputHdcp `
                                            -Session $sess `
                                            -Mode $outputRow.NewOutputHdcp `
                                            -OutputIndex ([int]$outputRow.OutputIndex)

                                        $stepResults += "OutputHdcp[$($outputRow.OutputIndex)]=$(if($rOutHdcp.Success){'OK'}else{$rOutHdcp.Status}) -> $($outputRow.NewOutputHdcp)"

                                        if (Test-ResultNeedsReboot $rOutHdcp) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rOutHdcp.Success) {
                                            $allOk = $false
                                        }
                                    }
                                } catch {
                                    $stepResults += "OutputHdcp[$($outputRow.OutputIndex)]=ERR: $($_.Exception.Message)"
                                    $allOk = $false
                                }
                            }

                            if ((Test-PerDeviceValue $outputRow.NewOutputResolution) -and "$($outputRow.NewOutputResolution)" -ne "$($outputRow.CurrentOutputResolution)") {
                                try {
                                    if (-not [bool]$outputRow.SupportsAvSettings) {
                                        $stepResults += "OutputResolution[$($outputRow.OutputIndex)]=skipped; unsupported"
                                        $allOk = $false
                                    }
                                    else {
                                        $rOutRes = Set-CrestronOutputResolution `
                                            -Session $sess `
                                            -Resolution $outputRow.NewOutputResolution `
                                            -OutputIndex ([int]$outputRow.OutputIndex)

                                        $stepResults += "OutputResolution[$($outputRow.OutputIndex)]=$(if($rOutRes.Success){'OK'}else{$rOutRes.Status}) -> $($outputRow.NewOutputResolution)"

                                        if (Test-ResultNeedsReboot $rOutRes) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rOutRes.Success) {
                                            $allOk = $false
                                        }
                                    }
                                } catch {
                                    $stepResults += "OutputResolution[$($outputRow.OutputIndex)]=ERR: $($_.Exception.Message)"
                                    $allOk = $false
                                }
                            }
                        }

                        foreach ($mcRow in @($row.MulticastRows)) {
                            if ((Test-PerDeviceValue $mcRow.NewMulticastAddress) -and "$($mcRow.NewMulticastAddress)" -ne "$($mcRow.CurrentMulticastAddress)") {
                                try {
                                    if (-not [bool]$mcRow.SupportsAvMulticast) {
                                        $stepResults += "Multicast[$($mcRow.Direction)]=skipped; unsupported"
                                        $allOk = $false
                                    }
                                    else {
                                        $rMc = Set-CrestronMulticastAddress `
                                            -Session $sess `
                                            -Direction $mcRow.Direction `
                                            -MulticastAddress $mcRow.NewMulticastAddress `
                                            -StreamIndex 0

                                        $stepResults += "Multicast=$(if($rMc.Success){'OK'}else{$rMc.Status}) -> $($mcRow.Direction) $($mcRow.NewMulticastAddress)[0]"

                                        if (Test-ResultNeedsReboot $rMc) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rMc.Success) {
                                            $allOk = $false
                                        }
                                    }
                                }
                                catch {
                                    $stepResults += "Multicast[$($mcRow.Direction)]=ERR: $($_.Exception.Message)"
                                    $allOk = $false
                                }
                            }
                        }

                        $currentMulticastAddress = ''
                        $modeForCurrentMulticast = "$($row.CurrentDeviceMode)"

                        if ($modeForCurrentMulticast -eq 'Receiver') {
                            $currentMulticastAddress = "$($row.CurrentReceiveMulticast)"
                        }
                        elseif ($modeForCurrentMulticast -eq 'Transmitter') {
                            $currentMulticastAddress = "$($row.CurrentTransmitMulticast)"
                        }

                        if ((Test-PerDeviceValue $row.NewMulticastAddress) -and "$($row.NewMulticastAddress)" -ne "$currentMulticastAddress") {
                            try {
                                if (-not [bool]$row.SupportsAvMulticast) {
                                    $stepResults += "Multicast=skipped; unsupported"
                                    $allOk = $false
                                }
                                else {
                                    $modeForMulticast = "$($row.DeviceMode)"
                                    if ([string]::IsNullOrWhiteSpace($modeForMulticast) -or @('Keep','N/A') -contains $modeForMulticast) {
                                        $modeForMulticast = "$($row.CurrentDeviceMode)"
                                    }

                                    $multicastDirection = switch ($modeForMulticast) {
                                        'Transmitter' { 'Transmit'; break }
                                        'Receiver'    { 'Receive'; break }
                                        default       { '' }
                                    }

                                    if (-not $multicastDirection) {
                                        $stepResults += "Multicast=skipped; TX/RX mode unavailable"
                                        $allOk = $false
                                    }
                                    else {
                                        $streamIndex = [int]$row.MulticastStreamIndex
                                        $rMc = Set-CrestronMulticastAddress `
                                            -Session $sess `
                                            -Direction $multicastDirection `
                                            -MulticastAddress $row.NewMulticastAddress `
                                            -StreamIndex $streamIndex

                                        $stepResults += "Multicast=$(if($rMc.Success){'OK'}else{$rMc.Status}) -> $multicastDirection $($row.NewMulticastAddress)[$streamIndex]"

                                        if (Test-ResultNeedsReboot $rMc) {
                                            $needsReboot = $true
                                        }

                                        if (-not $rMc.Success) {
                                            $allOk = $false
                                        }
                                    }
                                }
                            }
                            catch {
                                $stepResults += "Multicast=ERR: $($_.Exception.Message)"
                                $allOk = $false
                            }
                        }

                        if ($needsReboot) {
                            $stepResults += "REBOOT NEEDED"
                        }

                        $q.Enqueue([pscustomobject]@{
                            __result    = $true
                            IP          = $row.IP
                            Status      = if ($allOk) { 'OK' } else { 'Partial' }
                            Detail      = ($stepResults -join '; ')
                            NeedsReboot = $needsReboot
                            Timestamp   = (Get-Date).ToString('s')
                        })
                    } finally {
                        # Session may be invalid after IP change; Disconnect just cleans local jar
                        try { Disconnect-CrestronDevice -Session $sess } catch { }
                    }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        __result    = $true
                        IP          = $row.IP
                        Status      = 'Error'
                        Detail      = "ERROR: $($_.Exception.Message)"
                        NeedsReboot = $false
                        Timestamp   = (Get-Date).ToString('s')
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{
                __error = $_.Exception.Message
            })
        } finally {
            $doneRef.Value = $true
        }
    })

    $Script:PerDeviceState.Runspace    = $rs
    $Script:PerDeviceState.PowerShell  = $ps
    $Script:PerDeviceState.AsyncHandle = $ps.BeginInvoke()
    $Script:PerDeviceState.Queue       = $queue
    $Script:PerDeviceState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $item = $null

        while ($Script:PerDeviceState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Apply failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }

            $row = $Script:PerDeviceState.RowsByIP[$item.IP]
            if (-not $row) { continue }

            $row.Status = $item.Status

            if (-not $item.__progress) {
                $row.Detail      = $item.Detail
                $row.NeedsReboot = [bool]$item.NeedsReboot
                $row.Timestamp   = $item.Timestamp
            }
        }

        $Script:UI.PerDeviceGrid.Items.Refresh()
        $Script:UI.PerDeviceAvInputGrid.Items.Refresh()
        $Script:UI.PerDeviceAvOutputGrid.Items.Refresh()
        $Script:UI.PerDeviceMulticastGrid.Items.Refresh()
        Update-PerDeviceSummary

        if ($Script:PerDeviceState.DoneRef.Value -and $Script:PerDeviceState.Queue.IsEmpty) {
            Stop-PerDeviceRunspace
            Set-PerDeviceControls $false
            Save-PerDeviceCsv

            $ok = ($Script:PerDeviceState.Rows | Where-Object Status -eq 'OK').Count
            $Script:UI.PerDeviceProgressText.Text = "Done. $ok device(s) OK."
            Update-Status "Per-device apply complete. $ok OK. Saved $($Script:AppState.PerDeviceCsv)"

            Invoke-RebootNeededRows `
                -Rows @($Script:PerDeviceState.Rows) `
                -RowsByIP $Script:PerDeviceState.RowsByIP `
                -Grid $Script:UI.PerDeviceGrid `
                -UpdateSummary { Update-PerDeviceSummary } `
                -AreaName 'Per-Device'
        }
    })

    $timer.Start()
    $Script:PerDeviceState.Timer = $timer
}

function Stop-PerDeviceApply {
    if (-not $Script:PerDeviceState.IsRunning) { return }
    Stop-PerDeviceRunspace
    Set-PerDeviceControls $false
    $Script:UI.PerDeviceProgressText.Text = 'Cancelled.'
    Update-Status 'Per-device apply cancelled.'
}

# Auto-load on tab focus, then auto-fetch if device state hasn't been pulled yet
$Script:UI.PerDeviceTab.Add_GotFocus({
    if ($Script:PerDeviceState.Rows.Count -eq 0) {
        Load-PerDeviceFromProvision
    }
    # Auto-fetch state for any row missing a model
    $needFetch = @($Script:PerDeviceState.Rows | Where-Object { -not $_.Model -and -not $_.Detail })
    if ($needFetch.Count -gt 0 -and $Script:AppState.Credential) {
        Start-PerDeviceFetch
    }
})

$Script:UI.PerDeviceRefreshButton.Add_Click({ Start-PerDeviceFetch })
$Script:UI.PerDeviceApplyButton.Add_Click({ Start-PerDeviceApply })
$Script:UI.PerDeviceCancelButton.Add_Click({ Stop-PerDeviceApply })

$Script:UI.PerDeviceGrid.Add_BeginningEdit({
    param($sender, $e)

    $header = "$($e.Column.Header)"

    if ($header -in @('MC Address','MC Stream')) {
        $row = $e.Row.Item

        if (-not $row -or -not [bool]$row.SupportsAvMulticast) {
            $e.Cancel = $true
        }
    }

    if ($header -in @('Input HDCP','Output HDCP','Output Resolution')) {
        $row = $e.Row.Item

        if (-not $row -or -not [bool]$row.SupportsAvSettings) {
            $e.Cancel = $true
        }
    }

    if ($header -eq 'EDID') {
        $row = $e.Row.Item

        if (-not $row -or -not [bool]$row.SupportsEdidEdit) {
            $e.Cancel = $true
        }
    }

})

$Script:UI.PerDeviceGrid.Add_CellEditEnding({
    $Script:UI.PerDeviceGrid.Dispatcher.BeginInvoke([Action]{
        Update-PerDeviceSummary
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
})

$Script:UI.PerDeviceGrid.Add_CurrentCellChanged({
    Update-PerDeviceSummary
})

foreach ($grid in @($Script:UI.PerDeviceAvInputGrid, $Script:UI.PerDeviceAvOutputGrid, $Script:UI.PerDeviceMulticastGrid)) {
    $grid.Add_CellEditEnding({
        $Script:UI.PerDeviceGrid.Dispatcher.BeginInvoke([Action]{
            Update-PerDeviceSummary
        }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })

    $grid.Add_CurrentCellChanged({
        Update-PerDeviceSummary
    })
}

$window.Add_Closed({ Stop-PerDeviceRunspace })

# =============================================================================
# Reboot — shared helper used by Provision / Blanket / Per-Device tabs
# =============================================================================

$Script:RebootState = [pscustomobject]@{
    Runspace    = $null
    PowerShell  = $null
    AsyncHandle = $null
    Timer       = $null
    Queue       = $null
    DoneRef     = $null
}

function Stop-RebootRunspace {
    if ($Script:RebootState.Timer) {
        $Script:RebootState.Timer.Stop()
        $Script:RebootState.Timer = $null
    }
    if ($Script:RebootState.PowerShell) {
        try { $Script:RebootState.PowerShell.Stop() } catch {}
        try { $Script:RebootState.PowerShell.Dispose() } catch {}
        $Script:RebootState.PowerShell  = $null
        $Script:RebootState.AsyncHandle = $null
    }
    if ($Script:RebootState.Runspace) {
        try { $Script:RebootState.Runspace.Close() } catch {}
        try { $Script:RebootState.Runspace.Dispose() } catch {}
        $Script:RebootState.Runspace = $null
    }
}

function Show-RebootWaitDialog {
    param(
        [int]$Seconds = 240,
        [string]$Title = 'Waiting for devices to reboot',
        [string]$Message = 'Devices are rebooting. Please wait before continuing.'
    )

    if ($Seconds -lt 1) {
        $Seconds = 240
    }

    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Waiting for reboot"
        Width="500"
        Height="250"
        MinHeight="250"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        WindowStyle="ToolWindow">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <TextBlock x:Name="WaitMessage"
                   Grid.Row="0"
                   Text="Devices are rebooting. Please wait before continuing."
                   TextWrapping="Wrap"
                   Margin="0,0,0,12" />

        <ProgressBar x:Name="WaitProgress"
                     Grid.Row="1"
                     Height="22"
                     Minimum="0"
                     Maximum="100"
                     Value="0"
                     Margin="0,0,0,8" />

        <TextBlock x:Name="WaitCountdown"
                   Grid.Row="2"
                   Text="Starting..."
                   FontFamily="Consolas"
                   Foreground="#0066CC"
                   Margin="0,0,0,10" />

        <TextBlock Grid.Row="3"
                   Text="You can skip this wait if the devices are already back online. Cancel exits this wait screen."
                   Foreground="#666"
                   FontSize="11"
                   TextWrapping="Wrap"
                   Margin="0,0,0,10" />

        <StackPanel Grid.Row="4"
                    Orientation="Horizontal"
                    HorizontalAlignment="Right"
                    VerticalAlignment="Bottom">
            <Button x:Name="SkipButton"
                    Content="Skip Wait"
                    Width="100"
                    Padding="12,4"
                    Margin="0,0,8,0" />
            <Button x:Name="CancelButton"
                    Content="Cancel"
                    Width="90"
                    Padding="12,4" />
        </StackPanel>
    </Grid>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($dxaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)

    $dlg.Owner = $window
    $dlg.Title = $Title

    $messageText  = $dlg.FindName('WaitMessage')
    $bar          = $dlg.FindName('WaitProgress')
    $countdown    = $dlg.FindName('WaitCountdown')
    $skipButton   = $dlg.FindName('SkipButton')
    $cancelButton = $dlg.FindName('CancelButton')

    $messageText.Text = $Message

    $script:_rebootWaitResult = 'Completed'
    $startTime = Get-Date

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)

    $timer.Add_Tick({
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

        if ($elapsed -lt 0) {
            $elapsed = 0
        }

        if ($elapsed -gt $Seconds) {
            $elapsed = $Seconds
        }

        $remaining = $Seconds - $elapsed

        $percent = if ($Seconds -gt 0) {
            [Math]::Min(100, [Math]::Round(($elapsed / $Seconds) * 100, 0))
        }
        else {
            100
        }

        $bar.Value = $percent

        $mm = [Math]::Floor($remaining / 60)
        $ss = $remaining % 60

        $countdown.Text = ("Waiting: {0}:{1:D2} remaining ({2}% complete)" -f $mm, $ss, $percent)

        if ($elapsed -ge $Seconds) {
            $timer.Stop()
            $script:_rebootWaitResult = 'Completed'
            $dlg.DialogResult = $true
            $dlg.Close()
        }
    })

    $skipButton.Add_Click({
        $timer.Stop()
        $script:_rebootWaitResult = 'Skipped'
        $dlg.DialogResult = $true
        $dlg.Close()
    })

    $cancelButton.Add_Click({
        $timer.Stop()
        $script:_rebootWaitResult = 'Cancelled'
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $dlg.Add_ContentRendered({
        $timer.Start()
    })

    [void]$dlg.ShowDialog()

    if ($timer) {
        try { $timer.Stop() } catch { }
    }

    return $script:_rebootWaitResult
}

function Invoke-RebootBulk {
    param(
        [Parameter(Mandatory)]
        [object[]]$Ips,

        [scriptblock]$StatusCallback,

        [switch]$SkipConfirm,

        [switch]$SkipWait
    )

    if ($Ips.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No devices to reboot.", "Nothing selected", 'OK', 'Warning') | Out-Null
        return
    }

    $cred = Get-CachedCredential
    if (-not $cred) { Update-Status 'Reboot cancelled (no credentials).'; return }

    if (-not $SkipConfirm) {
        $msg = "Reboot $($Ips.Count) device(s)?`n`nThis will disconnect each device immediately. Pending settings changes will take effect after the reboot."
        $ans = [System.Windows.MessageBox]::Show($msg, "Confirm reboot", 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { Update-Status 'Reboot cancelled.'; return }
    }

    $Script:RebootWaitDeviceCount = @($Ips).Count
    $Script:RebootWaitAcceptedCount = 0

    Update-Status "Rebooting $($Ips.Count) device(s)..."

    $modManifest = (Get-Module CrestronAdminBootstrap).Path
    if (-not $modManifest) {
        $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap | Sort-Object Version -Descending | Select-Object -First 1).Path
    }

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',    $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',  $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',      $Ips)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip = $_
                $q  = $using:queue
                $u  = $using:userName
                $p  = $using:userPass
                $mp = $using:manifest
                try {
                    if (-not $mp -or -not (Test-Path $mp)) { throw "Module manifest path missing: '$mp'" }
                    Import-Module $mp -Force -ErrorAction Stop
                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred
                    try {
                        $r = Restart-CrestronDevice -Session $sess
                        $q.Enqueue([pscustomobject]@{
                            IP      = $ip
                            Status  = "$($r.Status)"
                            Success = "$($r.Success)"
                            Detail  = if ($r.Success) { 'Reboot signal accepted; device going offline' } else { $r.Response }
                        })
                    } finally {
                        try { Disconnect-CrestronDevice -Session $sess } catch {}
                    }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        IP      = $ip
                        Status  = '0'
                        Success = 'False'
                        Detail  = "ERROR: $($_.Exception.Message)"
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally { $doneRef.Value = $true }
    })

    $Script:RebootState.Runspace    = $rs
    $Script:RebootState.PowerShell  = $ps
    $Script:RebootState.AsyncHandle = $ps.BeginInvoke()
    $Script:RebootState.Queue       = $queue
    $Script:RebootState.DoneRef     = $doneRef

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        $item = $null

        while ($Script:RebootState.Queue.TryDequeue([ref]$item)) {
            if ($item.__error) {
                [System.Windows.MessageBox]::Show("Reboot failed: $($item.__error)", "Error", 'OK', 'Error') | Out-Null
                continue
            }

            if ($item.Success -eq 'True') {
                $Script:RebootWaitAcceptedCount++
            }

            if ($StatusCallback) {
                & $StatusCallback $item
            }
        }

        if ($Script:RebootState.DoneRef.Value -and $Script:RebootState.Queue.IsEmpty) {
            Stop-RebootRunspace
            Update-Status "Reboot Command Sent."

            if (-not $SkipWait -and $Script:RebootWaitAcceptedCount -gt 0) {
                $waitResult = Show-RebootWaitDialog `
                    -Seconds 240 `
                    -Title "Waiting for reboot" `
                    -Message "Reboot commands have been sent to $($Script:RebootWaitAcceptedCount) device(s). Wait up to 4 minutes before continuing."

                if ($waitResult -eq 'Cancelled') {
                    Update-Status 'Reboot wait cancelled by user.'
                }
                elseif ($waitResult -eq 'Skipped') {
                    Update-Status 'Reboot wait skipped by user.'
                }
                else {
                    Update-Status 'Reboot wait complete.'
                }
            }
            elseif (-not $SkipWait) {
                Update-Status 'No reboot commands were accepted; skipping reboot wait.'
            }
            else {
                Update-Status 'Reboot wait skipped for workflow.'
            }
        }
    }.GetNewClosure())
    $timer.Start()
    $Script:RebootState.Timer = $timer
}

# Provision tab — reboot selected
$Script:UI.ProvisionRebootButton.Add_Click({
    $ips = @($Script:ProvisionState.Rows | Where-Object Selected | Select-Object -ExpandProperty IP)
    Invoke-RebootBulk $ips {
        param($item)
        $row = $Script:ProvisionState.RowsByIP[$item.IP]
        if ($row) {
            $row.Status   = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Response = $item.Detail
            $row.Timestamp = (Get-Date).ToString('s')
        }
        $Script:UI.ProvisionGrid.Items.Refresh()
    }
})

# Blanket Settings tab — reboot selected
$Script:UI.BlanketRebootButton.Add_Click({
    $ips = @($Script:BlanketState.Rows | Where-Object NeedsReboot | Select-Object -ExpandProperty IP)
    Invoke-RebootBulk $ips {
        param($item)
        $row = $Script:BlanketState.RowsByIP[$item.IP]
        if ($row) {
            $row.Status = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Detail = $item.Detail

            if ($item.Success -eq 'True') {
                $row.NeedsReboot = $false
            }

            $row.Timestamp = (Get-Date).ToString('s')
        }
        $Script:UI.BlanketGrid.Items.Refresh()
    }
})

# Per-Device tab — reboot all loaded
$Script:UI.PerDeviceRebootButton.Add_Click({
    $ips = @($Script:PerDeviceState.Rows | Where-Object NeedsReboot | Select-Object -ExpandProperty IP)
    Invoke-RebootBulk $ips {
        param($item)
        $row = $Script:PerDeviceState.RowsByIP[$item.IP]
        if ($row) {
            $row.Status = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Detail = $item.Detail

            if ($item.Success -eq 'True') {
                $row.NeedsReboot = $false
            }

            $row.Timestamp = (Get-Date).ToString('s')
        }
        $Script:UI.PerDeviceGrid.Items.Refresh()
    }
})

$window.Add_Closed({ Stop-RebootRunspace })

# =============================================================================
# Full Workflow tab
# =============================================================================

$Script:WorkflowState = [pscustomobject]@{
    Steps         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    IsRunning     = $false
    PerDeviceWait = $false   # set true while paused for tech editing
    Cancelled     = $false
    Timer         = $null    # used to poll inner-tab work for completion
    CurrentStep   = -1
    PostRebootSec = 180
}
$Script:UI.WorkflowStepsList.ItemsSource = $Script:WorkflowState.Steps

function Initialize-WorkflowSteps {
    $Script:WorkflowState.Steps.Clear()
    foreach ($t in @(
        @{ Title='1. Scan';            Detail='Probe configured CIDRs for unprovisioned devices' },
        @{ Title='2. Provision';       Detail='Set the admin account on each found device' },
        @{ Title='3. Blanket Settings'; Detail='Apply NTP / Cloud / Auto-Update across all devices' },
        @{ Title='4. Per-Device';      Detail='Tech edits per-device hostname / IP / WiFi-off — pauses here' },
        @{ Title='5. Reboot';          Detail='Reboot all devices so changes take effect' },
        @{ Title='6. Verify';          Detail='Wait, then rescan to confirm provisioning stuck' }
    )) {
        $Script:WorkflowState.Steps.Add([pscustomobject]@{
            Icon   = '⏳'
            Title  = $t.Title
            Detail = $t.Detail
        })
    }
}
Initialize-WorkflowSteps

function Set-WorkflowControls ($running, $waitingForUser = $false) {
    $Script:WorkflowState.IsRunning            = $running
    $Script:UI.WorkflowStartButton.IsEnabled   = (-not $running) -and (-not $waitingForUser)
    $Script:UI.WorkflowContinueButton.IsEnabled = $waitingForUser
    $Script:UI.WorkflowCancelButton.IsEnabled  = $running
}

function Set-WorkflowStep ($index, $icon, $detail) {
    if ($index -lt 0 -or $index -ge $Script:WorkflowState.Steps.Count) { return }
    $step = $Script:WorkflowState.Steps[$index]
    $step.Icon = $icon
    if ($null -ne $detail) { $step.Detail = $detail }
    $Script:UI.WorkflowStepsList.Items.Refresh()
}

function Wait-ForInnerTab ($isRunningPredicate, $intervalMs = 250) {
    # Spin the WPF dispatcher until the inner tab's runspace work is done. We can't
    # block the UI thread, so we run a nested dispatcher frame.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($intervalMs)
    $timer.Add_Tick({
        if ($Script:WorkflowState.Cancelled) { $frame.Continue = $false; return }
        if (-not (& $isRunningPredicate))    { $frame.Continue = $false }
    })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    $timer.Stop()
}

function Show-WorkflowSettingsDialog {
    # Modal asking the tech which blanket-settings sections to apply.
    # Returns hashtable of choices, or $null if cancelled.
    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Blanket Settings for Workflow" Width="500" Height="380"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Border Grid.Row="0" BorderBrush="#DDD" BorderThickness="1" Padding="8" Margin="0,0,0,8">
            <StackPanel>
                <CheckBox x:Name="WNtpEnable" Content="Apply NTP / Time Zone" />
                <Grid Margin="20,6,0,0" IsEnabled="{Binding ElementName=WNtpEnable, Path=IsChecked}">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="80" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <TextBlock Text="Server"   Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" />
                    <TextBox  x:Name="WNtpServer"   Grid.Row="0" Grid.Column="1" Padding="4,2" Margin="0,0,0,4" Text="time.google.com" />
                    <TextBlock Text="Timezone" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" />
                    <ComboBox x:Name="WNtpTimeZone" Grid.Row="1" Grid.Column="1" Padding="4,2" />
                </Grid>
            </StackPanel>
        </Border>

        <Border Grid.Row="1" BorderBrush="#DDD" BorderThickness="1" Padding="8" Margin="0,0,0,8">
            <StackPanel>
                <CheckBox x:Name="WCloudEnable" Content="Apply XiO Cloud toggle" />
                <StackPanel Orientation="Horizontal" Margin="20,6,0,0" IsEnabled="{Binding ElementName=WCloudEnable, Path=IsChecked}">
                    <RadioButton x:Name="WCloudOn"  GroupName="WCloud" Content="Enable" IsChecked="True" Margin="0,0,16,0" />
                    <RadioButton x:Name="WCloudOff" GroupName="WCloud" Content="Disable" />
                </StackPanel>
            </StackPanel>
        </Border>

        <Border Grid.Row="2" BorderBrush="#DDD" BorderThickness="1" Padding="8">
            <StackPanel>
                <CheckBox x:Name="WAutoEnable" Content="Apply Auto-Update toggle" />
                <StackPanel Orientation="Horizontal" Margin="20,6,0,0" IsEnabled="{Binding ElementName=WAutoEnable, Path=IsChecked}">
                    <RadioButton x:Name="WAutoOn"  GroupName="WAuto" Content="Enable" IsChecked="True" Margin="0,0,16,0" />
                    <RadioButton x:Name="WAutoOff" GroupName="WAuto" Content="Disable" />
                </StackPanel>
            </StackPanel>
        </Border>

        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="WCancelBtn" Content="Skip Settings" Padding="14,4" Margin="0,0,8,0" />
            <Button x:Name="WOkBtn"     Content="Apply"         Padding="14,4" IsDefault="True" />
        </StackPanel>
    </Grid>
</Window>
'@
    $reader = [System.Xml.XmlNodeReader]::new($dxaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window

    $wTz = $dlg.FindName('WNtpTimeZone')
    $wTz.ItemsSource = $tzList
    $wTz.DisplayMemberPath = 'Name'
    $wTz.SelectedValuePath  = 'Code'
    $defTz = $tzList | Where-Object { $_.Code -eq '010' } | Select-Object -First 1
    if ($defTz) { $wTz.SelectedItem = $defTz }

    $script:_wfResult = $null
    $dlg.FindName('WOkBtn').Add_Click({
        $tz = $dlg.FindName('WNtpTimeZone').SelectedItem
        $script:_wfResult = [pscustomobject]@{
            NtpEnabled    = [bool]$dlg.FindName('WNtpEnable').IsChecked
            NtpServer     = $dlg.FindName('WNtpServer').Text.Trim()
            TimeZoneCode  = if ($tz) { $tz.Code } else { '010' }
            CloudEnabled  = [bool]$dlg.FindName('WCloudEnable').IsChecked
            CloudOn       = [bool]$dlg.FindName('WCloudOn').IsChecked
            AutoEnabled   = [bool]$dlg.FindName('WAutoEnable').IsChecked
            AutoOn        = [bool]$dlg.FindName('WAutoOn').IsChecked
        }
        $dlg.DialogResult = $true; $dlg.Close()
    })
    $dlg.FindName('WCancelBtn').Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    [void]$dlg.ShowDialog()
    return $script:_wfResult
}

function Reset-WorkflowSteps {
    Initialize-WorkflowSteps
    $Script:WorkflowState.Cancelled   = $false
    $Script:WorkflowState.CurrentStep = -1
}

function Start-FullWorkflow {
    if ($Script:WorkflowState.IsRunning) { return }
    Reset-WorkflowSteps
    Set-WorkflowControls $true
    $Script:UI.WorkflowStatusText.Text = 'Workflow running...'

    try {
        # --- Step 1: Scan ----------------------------------------------------
        $Script:WorkflowState.CurrentStep = 0
        Set-WorkflowStep 0 '⏸' 'Confirm or edit Subnets (CIDR) on the Scan tab, then click OK to start scanning.'
        $Script:UI.MainTabs.SelectedIndex = 1  # Scan tab

        Sync-ScanStateFromCheckedCidrs

        $cidrText = if ($Script:ScanState.Cidrs.Count -gt 0) {
            ($Script:ScanState.Cidrs -join "`n")
        } else {
            '(none)'
        }

        $scanConfirm = [System.Windows.MessageBox]::Show(
            "Confirm the Subnets (CIDR) list on the Scan tab before starting the Full Workflow scan.`n`nCurrent CIDRs:`n$cidrText`n`nClick OK to start scanning, or Cancel to stop the workflow.",
            "Confirm scan subnets",
            'OKCancel',
            'Question'
        )

        if ($scanConfirm -ne 'OK') {
            Set-WorkflowStep 0 'ℹ️' 'Workflow cancelled before scan.'
            return
        }

        Sync-ScanStateFromCheckedCidrs
        Save-ScanCidrs
        Set-WorkflowStep 0 '🔄' 'Scanning Network...'
        Start-Scan
        Wait-ForInnerTab { $Script:ScanState.IsScanning }
        if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
        $scanCount = $Script:ScanState.Results.Count
        if ($scanCount -eq 0) {
            Set-WorkflowStep 0 'ℹ️' 'No devices found. Stopping workflow.'
            return
        }
        Set-WorkflowStep 0 '✅' "Found $scanCount device(s) on bootup page."

        # --- Step 2: Provision ----------------------------------------------
        $Script:WorkflowState.CurrentStep = 1
        Set-WorkflowStep 1 '🔄' 'Provisioning admin accounts...'
        $Script:UI.MainTabs.SelectedIndex = 2  # Provision tab
        # Auto-load from in-memory scan results
        Load-ProvisionFromScan
        Start-Provision
        Wait-ForInnerTab { $Script:ProvisionState.IsRunning }
        if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
        $provOk = ($Script:ProvisionState.Rows | Where-Object Success -eq 'True').Count
        if ($provOk -eq 0) {
            Set-WorkflowStep 1 '❌' 'Zero devices provisioned. Stopping.'
            return
        }
        Set-WorkflowStep 1 '✅' "Provisioned $provOk device(s)."

        # --- Step 3: Blanket Settings ---------------------------------------
        $Script:WorkflowState.CurrentStep = 2
        Set-WorkflowStep 2 '⏸' 'Waiting for settings selection...'
        $choices = Show-WorkflowSettingsDialog
        if (-not $choices) {
            Set-WorkflowStep 2 'ℹ️' 'Skipped (user chose Skip Settings).'
        } elseif (-not ($choices.NtpEnabled -or $choices.CloudEnabled -or $choices.AutoEnabled)) {
            Set-WorkflowStep 2 'ℹ️' 'Skipped (no sections enabled).'
        } else {
            Set-WorkflowStep 2 '🔄' 'Applying blanket settings...'
            $Script:UI.MainTabs.SelectedIndex = 3  # Blanket Settings tab
            Load-BlanketFromProvision

            # Apply the dialog choices to the visible tab controls so Start-BlanketApply
            # picks them up. This reuses the existing apply logic.
            $Script:UI.NtpEnableBox.IsChecked        = $choices.NtpEnabled
            $Script:UI.NtpServerBox.Text             = $choices.NtpServer
            $tzPick = $tzList | Where-Object Code -eq $choices.TimeZoneCode | Select-Object -First 1
            if ($tzPick) { $Script:UI.NtpTimeZoneBox.SelectedItem = $tzPick }
            $Script:UI.CloudEnableBox.IsChecked      = $choices.CloudEnabled
            $Script:UI.CloudOnRadio.IsChecked        = $choices.CloudOn
            $Script:UI.CloudOffRadio.IsChecked       = (-not $choices.CloudOn)
            $Script:UI.AutoUpdateEnableBox.IsChecked = $choices.AutoEnabled
            $Script:UI.AutoUpdateOnRadio.IsChecked   = $choices.AutoOn
            $Script:UI.AutoUpdateOffRadio.IsChecked  = (-not $choices.AutoOn)

            # Start-BlanketApply requires a YES confirm dialog. To stay automatic in
            # the workflow, we set a sentinel and let the existing logic prompt — it's
            # one dialog, predictable for the tech.
            Start-BlanketApply
            Wait-ForInnerTab { $Script:BlanketState.IsRunning }
            if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
            $blankOk = ($Script:BlanketState.Rows | Where-Object Status -eq 'OK').Count
            Set-WorkflowStep 2 '✅' "Applied to $blankOk device(s)."
        }

        # --- Step 4: Per-Device (pause for editing) -------------------------
        $Script:WorkflowState.CurrentStep = 3
        Set-WorkflowStep 3 '⏸' 'Switched to Per-Device tab. Edit values then click "Continue Workflow".'
        $Script:UI.MainTabs.SelectedIndex = 4  # Per-Device
        Load-PerDeviceFromProvision

        Set-WorkflowControls $true $true  # waiting for user
        $Script:WorkflowState.PerDeviceWait = $true
        # Wait until user clicks Continue or Cancel
        Wait-ForInnerTab { $Script:WorkflowState.PerDeviceWait }
        Set-WorkflowControls $true $false
        if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }

        Set-WorkflowStep 3 '🔄' 'Applying per-device changes...'
        Start-PerDeviceApply
        Wait-ForInnerTab { $Script:PerDeviceState.IsRunning }
        if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
        $pdOk = ($Script:PerDeviceState.Rows | Where-Object Status -eq 'OK').Count
        if ($pdOk -eq 0) {
            Set-WorkflowStep 3 'ℹ️' 'No per-device changes applied (or all skipped).'
        } else {
            Set-WorkflowStep 3 '✅' "Applied to $pdOk device(s)."
        }

        # --- Step 5: Reboot --------------------------------------------------
        $Script:WorkflowState.CurrentStep = 4
        Set-WorkflowStep 4 '🔄' 'Rebooting devices...'
        $rebootIps = @($Script:ProvisionState.Rows | Where-Object Success -eq 'True' | Select-Object -ExpandProperty IP)
        if ($rebootIps.Count -eq 0) {
            Set-WorkflowStep 4 'ℹ️' 'No devices to reboot.'
        } else {
            # Use the shared reboot helper. It pops its own confirm dialog.
            Invoke-RebootBulk -Ips $rebootIps -StatusCallback { param($item) } -SkipWait
            # Wait for reboot runspace to drain
            Wait-ForInnerTab { $null -ne $Script:RebootState.PowerShell }
            if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
            Set-WorkflowStep 4 '✅' "Reboot signal sent to $($rebootIps.Count) device(s)."
        }

        # --- Step 6: Wait for reboot + Verify --------------------------------
        # Bumped to 4 minutes total. Probes GET / on each device every 5 seconds.
        # When all rebooted devices come back, we exit the wait early and proceed
        # straight to Verify.
        $Script:WorkflowState.CurrentStep = 5
        $waitSec = 240  # 4 minutes hard cap

        # Build live reboot-status rows
        $rebootRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        $rebootByIp = @{}
        foreach ($ip in $rebootIps) {
            $r = [pscustomobject]@{ IP = $ip; Status = 'Booting'; FirstOnlineAt = '' }
            $rebootRows.Add($r)
            $rebootByIp[$ip] = $r
        }
        $Script:UI.WorkflowRebootGrid.ItemsSource = $rebootRows
        $Script:UI.WorkflowRebootPanel.Visibility = 'Visible'

        $elapsed = 0
        $allOnline = $false
        while ($elapsed -lt $waitSec) {
            if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }

            $remaining = $waitSec - $elapsed
            $mm = [Math]::Floor($remaining / 60)
            $ss = $remaining % 60
            $Script:UI.WorkflowCountdownText.Text = ("Countdown: {0}:{1:D2}" -f $mm, $ss)

            # Probe each not-yet-online device with a 2-second HTTPS GET /
            $stillBooting = @($rebootRows | Where-Object Status -eq 'Booting')
            foreach ($r in $stillBooting) {
                $probeOk = $false
                try {
                    & curl.exe -k -s -o NUL --max-time 2 `
                        -w "%{http_code}" "https://$($r.IP)/" 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $probeOk = $true }
                } catch { }
                if ($probeOk) {
                    $r.Status        = 'Online'
                    $r.FirstOnlineAt = (Get-Date).ToString('HH:mm:ss')
                }
            }
            $online = ($rebootRows | Where-Object Status -eq 'Online').Count
            $total  = $rebootRows.Count
            $Script:UI.WorkflowOnlineText.Text = "$online of $total online"
            $Script:UI.WorkflowRebootGrid.Items.Refresh()

            Set-WorkflowStep 5 '⏳' ("Waiting for reboot: {0}/{1} online, {2}s remaining" -f $online, $total, $remaining)

            if ($online -eq $total -and $total -gt 0) {
                $allOnline = $true
                break
            }

            # Pump dispatcher for 5 seconds, then re-probe
            $f = New-Object System.Windows.Threading.DispatcherFrame
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromSeconds(5)
            $t.Add_Tick({ $f.Continue = $false })
            $t.Start()
            [System.Windows.Threading.Dispatcher]::PushFrame($f)
            $t.Stop()
            $elapsed += 5
        }

        # Final summary on the reboot wait
        $online = ($rebootRows | Where-Object Status -eq 'Online').Count
        $total  = $rebootRows.Count
        if ($allOnline) {
            Set-WorkflowStep 5 '✅' "All $total device(s) back online (early exit)."
        } else {
            $offline = $total - $online
            Set-WorkflowStep 5 'ℹ️' "$online of $total back online ($offline still booting after 4 min). Verifying anyway."
        }

        # --- Step 6: Verify --------------------------------------------------
        $Script:WorkflowState.CurrentStep = 5
        Set-WorkflowStep 5 '🔄' 'Verifying after reboot wait...'
        $Script:UI.WorkflowStatusText.Text = 'Verifying...'

        $Script:UI.MainTabs.SelectedIndex = 5  # Verify
        Load-VerifyFromProvision
        Start-Verify
        Wait-ForInnerTab { $Script:VerifyState.IsRunning }

        if ($Script:WorkflowState.Cancelled) {
            throw 'Cancelled by user.'
        }

        $verified = ($Script:VerifyState.Rows | Where-Object Verified -eq 'True').Count
        $total = $Script:VerifyState.Rows.Count

        Set-WorkflowStep 5 '✅' "Verify: $verified/$total past bootup."

    }
    catch {
        $Script:UI.WorkflowStatusText.Text = "Workflow stopped: $($_.Exception.Message)"
        Update-Status "Workflow stopped: $($_.Exception.Message)"
        if ($Script:WorkflowState.CurrentStep -ge 0) {
            Set-WorkflowStep $Script:WorkflowState.CurrentStep '❌' $_.Exception.Message
        }
    }
    finally {
        Set-WorkflowControls $false
        $Script:UI.MainTabs.SelectedIndex = 0  # back to Workflow tab
    }
}

$Script:UI.WorkflowStartButton.Add_Click({ Start-FullWorkflow })

$Script:UI.WorkflowContinueButton.Add_Click({
    $Script:WorkflowState.PerDeviceWait = $false
    $Script:UI.WorkflowContinueButton.IsEnabled = $false
    $Script:UI.MainTabs.SelectedIndex = 0
})

$Script:UI.WorkflowCancelButton.Add_Click({
    $Script:WorkflowState.Cancelled     = $true
    $Script:WorkflowState.PerDeviceWait = $false
    Stop-Scan
    Stop-Provision
    Stop-BlanketApply
    Stop-PerDeviceApply
    Stop-RebootRunspace
    Stop-Verify
    Update-Status 'Workflow cancellation requested.'
})

# =============================================================================
# Wire "Add Devices..." dialog to Per-Device + Blanket tabs
# =============================================================================

function Add-DevicesToGrid {
    <#
    Shared logic: open the dialog, probe IPs, merge new ones into the target
    grid's row collection. $RowsByIP is the row dict.
    #>
    param(
        [System.Collections.ObjectModel.ObservableCollection[object]]$Rows,
        [hashtable]$RowsByIP,
        [scriptblock]$RowFactory   # called as { param($ip) ; ... } to make a new row
    )

    $candidateIps = Show-AddDevicesDialog

    if (-not $candidateIps -or $candidateIps.Count -eq 0) {
        return
    }

    # Filter out IPs already in the grid.
    $newIps = @($candidateIps | Where-Object { -not $RowsByIP.ContainsKey($_) })
    $skipped = $candidateIps.Count - $newIps.Count

    if ($newIps.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "All $($candidateIps.Count) IP(s) are already loaded.",
            "Nothing to add",
            'OK',
            'Information'
        ) | Out-Null

        return
    }

    Update-Status "Scanning $($newIps.Count) candidate IP(s)..."

    $probeResults = Show-ProbingDialog `
        -Title "Adding devices" `
        -Message "Scanning $($newIps.Count) IP(s) on the network, please wait..." `
        -Work {
            Find-DevicesReachable -Ips $newIps -Credential $Script:AppState.Credential
        }

    $reachableObjs = @($probeResults | Where-Object Reachable)

    if ($reachableObjs.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No Crestron devices responded among $($newIps.Count) IP(s).",
            "No devices found",
            'OK',
            'Warning'
        ) | Out-Null

        Update-Status "No responsive Crestron devices found."
        return
    }

    $authOk   = @($reachableObjs | Where-Object Authenticated)
    $authFail = @($reachableObjs | Where-Object { -not $_.Authenticated -and $Script:AppState.Credential })
    $noTested = @($reachableObjs | Where-Object { -not $Script:AppState.Credential })

    foreach ($obj in $reachableObjs) {
        $row = & $RowFactory $obj.IP

        # If the row has a Detail field, surface auth failure there so the tech sees it.
        if ($null -ne $row.PSObject.Properties['Detail']) {
            if ($Script:AppState.Credential) {
                if ($obj.Authenticated) {
                    $row.Detail = 'Auth OK'
                }
                else {
                    $row.Detail = "Auth FAILED: $($obj.AuthDetail)"

                    if ($null -ne $row.PSObject.Properties['Status']) {
                        $row.Status = 'AuthFail'
                    }
                }
            }
        }

        $Rows.Add($row)
        $RowsByIP[$obj.IP] = $row
    }

    $bits = @()
    $bits += "Added $($reachableObjs.Count) device(s)"

    if ($authOk.Count -gt 0) {
        $bits += "Auth OK: $($authOk.Count)"
    }

    if ($authFail.Count -gt 0) {
        $bits += "Auth failed: $($authFail.Count)"
    }

    if ($noTested.Count -gt 0) {
        $bits += "Not tested (no creds): $($noTested.Count)"
    }

    if ($skipped -gt 0) {
        $bits += "Skipped (already loaded): $skipped"
    }

    if ($reachableObjs.Count -lt $newIps.Count) {
        $bits += "Unreachable: $($newIps.Count - $reachableObjs.Count)"
    }

    Update-Status ($bits -join '. ')

    if ($authFail.Count -gt 0) {
        $sample = $authFail | Select-Object -First 3
        $sampleDetail = ($sample | ForEach-Object {
            "  $($_.IP):  $($_.AuthDetail)"
        }) -join "`n"

        $failedIps = ($authFail | Select-Object -ExpandProperty IP) -join ', '

        [System.Windows.MessageBox]::Show(
            "$($authFail.Count) device(s) failed authentication with the cached credentials:`n`n$failedIps`n`nFirst few errors:`n$sampleDetail`n`nIf the credentials work in the web UI but fail here, copy the error message and share it.",
            "Some devices failed authentication",
            'OK',
            'Warning'
        ) | Out-Null
    }
}

$Script:UI.PerDeviceAddButton.Add_Click({
    Add-DevicesToGrid `
        -Rows $Script:PerDeviceState.Rows `
        -RowsByIP $Script:PerDeviceState.RowsByIP `
        -RowFactory {
            param($ip)
            [pscustomobject]@{
                IP                       = $ip
                Model                    = ''
                CurrentHostname          = ''
                CurrentDhcp              = $null
                CurrentWifi              = $null
                SupportsNetwork          = $false
                SupportsIpTable          = $false
                HasWifi                  = $false
                CurrentIP                = ''
                CurrentSubnet            = ''
                CurrentGateway           = ''
                CurrentDns1              = ''
                CurrentDns2              = ''
                CurrentIpId              = ''
                CurrentControlSystemAddr = ''
                CurrentRoomId            = ''
                CurrentDeviceMode        = ''
                SupportsModeChange       = $false
                AvApiFamily              = ''
                AvApiVersion             = ''
                SupportsAvSettings       = $false
                SupportsGlobalEdid       = $false
                SupportsInputEdid        = $false
                SupportsEdidEdit         = $false
                EdidNameOptions          = @()
                EdidNames                = ''
                SupportsAvMulticast      = $false
                CurrentTransmitMulticast = ''
                CurrentReceiveMulticast  = ''
                CurrentInputHdcp         = ''
                CurrentOutputHdcp        = ''
                CurrentOutputResolution  = ''
                CurrentGlobalEdid        = ''
                NewHostname              = 'N/A'
                IPMode                   = 'N/A'
                DeviceMode               = 'N/A'
                NewInputHdcp             = 'N/A'
                NewOutputHdcp            = 'N/A'
                NewOutputResolution      = 'N/A'
                NewGlobalEdidName        = 'N/A'
                NewMulticastAddress      = 'N/A'
                MulticastStreamIndex     = 'N/A'
                NewIP                    = 'N/A'
                SubnetMask               = 'N/A'
                Gateway                  = 'N/A'
                PrimaryDns               = 'N/A'
                SecondaryDns             = 'N/A'
                DisableWifi              = $false
                NewIpId                  = 'N/A'
                NewControlSystemAddr     = 'N/A'
                NewRoomId                = ''
                Status                   = ''
                Detail                   = ''
                NeedsReboot              = $false
                Timestamp                = ''
            }
        }
    Update-PerDeviceSummary
    # Auto-fetch state for the new rows if creds are cached
    if ($Script:AppState.Credential) {
        Start-PerDeviceFetch
    } else {
        Update-Status "Devices added. Click 'Fetch current state' to populate hostname/model after entering credentials."
    }
})

$Script:UI.PerDeviceClearButton.Add_Click({
    $count = $Script:PerDeviceState.Rows.Count
    if ($count -eq 0) {
        Update-Status 'Nothing to clear.'
        return
    }
    $r = [System.Windows.MessageBox]::Show(
        "Remove all $count device(s) from the Per-Device tab?",
        "Clear Loaded", 'YesNo', 'Question'
    )
    if ($r -eq 'Yes') {
        $Script:PerDeviceState.Rows.Clear()
        $Script:PerDeviceState.RowsByIP.Clear()
        $Script:PerDeviceState.AvInputRows.Clear()
        $Script:PerDeviceState.AvOutputRows.Clear()
        $Script:PerDeviceState.MulticastRows.Clear()
        Update-PerDeviceSummary
        Update-Status "Cleared $count device(s) from Per-Device tab."
    }
})
# Blanket Settings uses the shared add-device dialog while still auto-loading
# provisioned devices the first time the tab is focused.
$Script:UI.BlanketReloadButton.Add_Click({
    Add-DevicesToGrid `
        -Rows $Script:BlanketState.Rows `
        -RowsByIP $Script:BlanketState.RowsByIP `
        -RowFactory {
            param($ip)
            [pscustomobject]@{
                Selected            = $true
                IP                  = $ip
                Model               = ''
                CurrentDeviceMode   = ''
                AvApiFamily         = ''
                AvApiVersion        = ''
                SupportsAvSettings  = $false
                SupportsAvMulticast = $false
                SupportsGlobalEdid  = $false
                EdidNames           = ''
                SupportsModeChange  = $false
                SupportsNtp         = $false
                SupportsCloud       = $false
                SupportsFusion      = $false
                SupportsAutoUpdate  = $false
                SupportsIpTable     = $false
                SupportsNetwork     = $false
                SupportsWifi        = $false
                CapabilitiesFetched = $false
                Status              = ''
                Sections            = ''
                Detail              = ''
                NeedsReboot         = $false
                Timestamp           = ''
            }
        }
    Update-BlanketSummary
})

# ---- Global exception handlers -----------------------------------------------
# Without these, any unhandled exception inside an event handler (e.g. a
# button click that hits a bug) kills the dispatcher silently and the GUI
# vanishes. We surface them as message boxes and keep running.

$dispatcherHandler = {
    param($sender, $e)
    try {
        $msg = "$($e.Exception.GetType().Name): $($e.Exception.Message)"
        if ($e.Exception.InnerException) {
            $msg += "`n`nInner: $($e.Exception.InnerException.Message)"
        }
        [System.Windows.MessageBox]::Show(
            "An unexpected error occurred:`n`n$msg`n`nThe application will keep running. If this happens repeatedly, please copy this message and report it.",
            "Unexpected error",
            'OK', 'Error'
        ) | Out-Null
        $e.Handled = $true
    } catch {
        # Last-ditch: never let the handler itself crash
    }
}
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException($dispatcherHandler)

# Also catch exceptions on background AppDomain threads (e.g. timer ticks
# whose dispatcher chain unwound before WPF saw it).
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    try {
        $ex = $e.ExceptionObject
        [System.Windows.MessageBox]::Show(
            "Background error:`n`n$($ex.Message)",
            "Background error", 'OK', 'Error'
        ) | Out-Null
    } catch { }
})

# =============================================================================
# Add Devices — shared dialog + discovery helper
# =============================================================================

function Show-ProbingDialog {
    <#
    Modal dialog with an indeterminate progress bar. Runs the supplied
    scriptblock after the dialog renders, then closes when the work finishes.
    Returns whatever the scriptblock returns.
    #>
    param(
        [string]$Title = 'Adding devices',
        [string]$Message = 'Working, please wait...',
        [Parameter(Mandatory)][scriptblock]$Work
    )

    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Working" Width="440" Height="150"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow">
    <StackPanel Margin="20" VerticalAlignment="Center">
        <TextBlock x:Name="ProbingText" Text="Working, please wait..." Margin="0,0,0,10" TextWrapping="Wrap" />
        <TextBlock x:Name="ProbingStatusText" Text="Starting..." Margin="0,8,0,0" Foreground="#666" />
    </StackPanel>
</Window>
'@

    $reader = [System.Xml.XmlNodeReader]::new($dxaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)

    $dlg.Owner = $window
    $dlg.Title = $Title

    $dlg.FindName('ProbingText').Text = $Message
    $dlg.FindName('ProbingStatusText').Text = 'Scanning Network...'

    $script:_probeResult = $null
    $script:_probeError  = $null

    $dlg.Add_ContentRendered({
        $dlg.Dispatcher.BeginInvoke(
            [Action]{
                try {
                    $script:_probeResult = & $Work
                }
                catch {
                    $script:_probeError = $_.Exception.Message
                }
                finally {
                    $dlg.DialogResult = $true
                    $dlg.Close()
                }
            },
            [System.Windows.Threading.DispatcherPriority]::ApplicationIdle
        ) | Out-Null
    })

    [void]$dlg.ShowDialog()

    if ($script:_probeError) {
        throw $script:_probeError
    }

    return $script:_probeResult
}

function Show-AddDevicesDialog {
    <#
    Opens a modal with 3 tabs (CIDR scan / IP list / Provisioning CSV) and
    returns an array of IP strings to add. Returns @() if the user cancelled.
    #>
    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Devices" Width="580" Height="460"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <DockPanel Margin="12">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="AddCancelBtn" Content="Cancel" Padding="14,4" Margin="0,0,8,0" />
            <Button x:Name="AddOkBtn"     Content="Discover and Add" Padding="14,4" IsDefault="True" />
        </StackPanel>

        <TabControl x:Name="AddTabs">
            <TabItem Header="CIDR Scan">
                <DockPanel Margin="8">
                    <TextBlock DockPanel.Dock="Top"
                            Text="Select subnet(s) to scan. Subnets come from Settings → Most Used Subnets."
                            Foreground="#666"
                            Margin="0,0,0,4"
                            TextWrapping="Wrap" />

                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBox x:Name="AddCidrManualBox"
                                 Grid.Column="0"
                                 Padding="4,2"
                                 VerticalContentAlignment="Center" />
                        <Button x:Name="AddCidrManualButton"
                                Grid.Column="1"
                                Content="Add Subnet"
                                Margin="6,0,0,0"
                                Padding="10,2" />
                    </Grid>

                    <TextBlock x:Name="AddCidrStatusText"
                               DockPanel.Dock="Bottom"
                               Foreground="#666"
                               FontSize="11"
                               Margin="0,6,0,0" />

                    <ScrollViewer VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Auto">
                        <StackPanel x:Name="AddCidrCheckList" />
                    </ScrollViewer>
                </DockPanel>
            </TabItem>
            <TabItem Header="IP List">
                <DockPanel Margin="8">
                    <TextBlock DockPanel.Dock="Top" Text="Paste IPs (one per line, or comma-separated)." Foreground="#666" Margin="0,0,0,4" />
                    <TextBox x:Name="AddIpsBox" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" FontFamily="Consolas" />
                </DockPanel>
            </TabItem>
            <TabItem Header="Provisioning CSV">
                <DockPanel Margin="8">
                    <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#666" Margin="0,0,0,4"
                               Text="Loads IPs from the most recent crestron-provisioned.csv in this workspace (Success rows only)." />
                    <TextBlock x:Name="AddCsvSummary" Foreground="#444" />
                </DockPanel>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@
    $reader = [System.Xml.XmlNodeReader]::new($dxaml)
    $dlg = [Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window

    $tabs       = $dlg.FindName('AddTabs')
    $cidrList   = $dlg.FindName('AddCidrCheckList')
    $cidrBox    = $dlg.FindName('AddCidrManualBox')
    $cidrAddBtn = $dlg.FindName('AddCidrManualButton')
    $cidrStatus = $dlg.FindName('AddCidrStatusText')
    $ipsBox     = $dlg.FindName('AddIpsBox')
    $csvSummary = $dlg.FindName('AddCsvSummary')
    $okBtn      = $dlg.FindName('AddOkBtn')
    $cancelBtn  = $dlg.FindName('AddCancelBtn')
    $cidrRegex  = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
    $defaultCidrs = @()

    $addCidrCheckbox = {
        param(
            [string]$Cidr,
            [bool]$Checked = $true
        )

        $trimmed = "$Cidr".Trim()

        if ($trimmed -notmatch $cidrRegex) {
            return $false
        }

        foreach ($child in $cidrList.Children) {
            if ("$($child.Content)" -eq $trimmed) {
                $child.IsChecked = $Checked
                return $true
            }
        }

        $check = New-Object System.Windows.Controls.CheckBox
        $check.Content = $trimmed
        $check.IsChecked = $Checked
        $check.Margin = '2,2,2,2'
        [void]$cidrList.Children.Add($check)

        return $true
    }

    $addManualCidr = {
        $entry = $cidrBox.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($entry)) {
            $cidrStatus.Text = 'Enter a CIDR subnet to add.'
            return
        }

        if ($entry -notmatch $cidrRegex) {
            [System.Windows.MessageBox]::Show(
                "Invalid CIDR. Example: 192.168.20.0/24",
                "Invalid input",
                'OK',
                'Warning'
            ) | Out-Null
            return
        }

        if (& $addCidrCheckbox $entry $true) {
            $cidrBox.Clear()
            $cidrStatus.Text = "Added $entry to this scan."
        }
    }

    if ($Script:GuiSettings -and
        $Script:GuiSettings.PSObject.Properties.Name -contains 'MostUsedSubnets' -and
        $Script:GuiSettings.MostUsedSubnets) {

        $defaultCidrs = @($Script:GuiSettings.MostUsedSubnets | Where-Object {
            $_ -match $cidrRegex
        })
    }

    if ($defaultCidrs.Count -eq 0 -and $Script:ScanState -and $Script:ScanState.Cidrs.Count -gt 0) {
        $defaultCidrs = @($Script:ScanState.Cidrs | Where-Object {
            $_ -match $cidrRegex
        })
    }

    foreach ($cidr in $defaultCidrs) {
        & $addCidrCheckbox $cidr $true | Out-Null
    }

    $cidrAddBtn.Add_Click({ & $addManualCidr })
    $cidrBox.Add_KeyDown({
        param($sender, $e)

        if ($e.Key -eq 'Return') {
            & $addManualCidr
            $e.Handled = $true
        }
    })

    # Pre-compute CSV summary
    if (Test-Path $Script:AppState.ProvisionCsv) {
        try {
            $csvRows = @(Import-Csv $Script:AppState.ProvisionCsv | Where-Object { $_.IP -and $_.Success -eq 'True' })
            $csvSummary.Text = "$($csvRows.Count) device(s) in: $($Script:AppState.ProvisionCsv)"
        } catch {
            $csvSummary.Text = "Could not read CSV: $($_.Exception.Message)"
        }
    } else {
        $csvSummary.Text = "No crestron-provisioned.csv in this workspace yet."
    }

    $script:_addResult = @()

    $okBtn.Add_Click({
        $idx = $tabs.SelectedIndex
        $result = @()
        switch ($idx) {
            0 {  # CIDR
                $cidrs = @()

                foreach ($item in $cidrList.Children) {
                    if ([bool]$item.IsChecked) {
                        $cidrs += "$($item.Content)"
                    }
                }

                if ($cidrs.Count -eq 0) {
                    [System.Windows.MessageBox]::Show(
                        "Select at least one subnet to scan.",
                        "No subnet selected",
                        'OK',
                        'Warning'
                    ) | Out-Null
                    return
                }

                foreach ($cidr in $cidrs) {
                    $result += Expand-CidrToIps $cidr
                }
            }
            1 {  # IP list
                $raw = $ipsBox.Text -replace ',', "`n"
                $list = $raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
                if ($list.Count -eq 0) {
                    [System.Windows.MessageBox]::Show("No valid IPs entered.", "Invalid input", 'OK', 'Warning') | Out-Null
                    return
                }
                $result = @($list)
            }
            2 {  # CSV
                if (Test-Path $Script:AppState.ProvisionCsv) {
                    try {
                        $result = @(Import-Csv $Script:AppState.ProvisionCsv |
                                    Where-Object { $_.IP -and $_.Success -eq 'True' } |
                                    Select-Object -ExpandProperty IP)
                    } catch {
                        [System.Windows.MessageBox]::Show("Failed to read CSV: $($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
                        return
                    }
                }
                if ($result.Count -eq 0) {
                    [System.Windows.MessageBox]::Show("No provisioned devices found in the CSV.", "Empty CSV", 'OK', 'Warning') | Out-Null
                    return
                }
            }
        }
        $script:_addResult = $result | Sort-Object -Unique
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $cancelBtn.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    [void]$dlg.ShowDialog()
    return ,$script:_addResult
}

function Expand-CidrToIps ($cidr) {
    # Tiny CIDR-to-IP-list expander. Limited to /22 or smaller (1024 IPs)
    # to prevent runaway expansion.
    if ($cidr -notmatch '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') { return @() }
    $base = $Matches[1]
    $bits = [int]$Matches[2]
    if ($bits -lt 22) { return @() }

    $hostBits = 32 - $bits
    $count    = [Math]::Pow(2, $hostBits)
    $octets   = $base -split '\.' | ForEach-Object { [int]$_ }
    $startInt = ($octets[0] -shl 24) -bor ($octets[1] -shl 16) -bor ($octets[2] -shl 8) -bor $octets[3]
    $mask     = ([uint32]::MaxValue -shl $hostBits) -band [uint32]::MaxValue
    $netStart = $startInt -band $mask
    $netEnd   = $netStart + $count - 1

    $ips = @()
    # Skip network and broadcast on /24 and smaller
    $skipNetBcast = $bits -ge 24
    $lo = if ($skipNetBcast) { $netStart + 1 } else { $netStart }
    $hi = if ($skipNetBcast) { $netEnd   - 1 } else { $netEnd }
    for ($i = $lo; $i -le $hi; $i++) {
        $ips += '{0}.{1}.{2}.{3}' -f (($i -shr 24) -band 0xFF), (($i -shr 16) -band 0xFF), (($i -shr 8) -band 0xFF), ($i -band 0xFF)
    }
    return $ips
}

function Find-DevicesReachable {
    <#
    Pings each IP, then probes responsive ones with HTTPS GET /. Returns
    one object per responsive IP with:
      IP, Reachable, Authenticated, AuthDetail.
    If Credential is supplied, also attempts login and reports auth status.
    #>
    param(
        [string[]]$Ips,
        [pscredential]$Credential,
        [int]$PingTimeoutMs = 400,
        [int]$HttpsTimeoutSec = 3
    )

    if ($Ips.Count -eq 0) { return @() }

    $manifest = (Get-Module CrestronAdminBootstrap).Path
    if (-not $manifest) {
        $manifest = (Get-Module -ListAvailable CrestronAdminBootstrap | Sort-Object Version -Descending | Select-Object -First 1).Path
    }

    $userName = $null; $userPass = $null
    if ($Credential) {
        $userName = $Credential.UserName
        $userPass = $Credential.GetNetworkCredential().Password
    }

    $results = @($Ips | ForEach-Object -ThrottleLimit 64 -Parallel {
        $ip       = $_
        $pingTo   = $using:PingTimeoutMs
        $httpsTo  = $using:HttpsTimeoutSec
        $mp       = $using:manifest
        $u        = $using:userName
        $p        = $using:userPass

        $out = [pscustomobject]@{
            IP            = $ip
            Reachable     = $false
            Authenticated = $false
            AuthDetail    = ''
        }

        try {
            $ping = [System.Net.NetworkInformation.Ping]::new()
            $r = $ping.Send($ip, $pingTo)
            if ($r.Status -ne 'Success') { return $out }

            # CresNext probe
            $jar = Join-Path ([IO.Path]::GetTempPath()) "cabs-probe-$([Guid]::NewGuid()).txt"
            try {
                & curl.exe -k -s -c $jar --max-time $httpsTo -o NUL "https://$ip/" 2>$null | Out-Null
                if (-not ((Test-Path $jar) -and (Select-String -Path $jar -Pattern 'TRACKID' -Quiet))) {
                    return $out
                }
            } finally {
                Remove-Item $jar -Force -ErrorAction SilentlyContinue
            }

            $out.Reachable = $true

            # Optional credential test
            if ($u -and $p -and $mp -and (Test-Path $mp)) {
                try {
                    Import-Module $mp -Force -ErrorAction Stop
                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred
                    try {
                        $out.Authenticated = $true
                        $out.AuthDetail    = 'OK'
                    } finally {
                        Disconnect-CrestronDevice -Session $sess
                    }
                } catch {
                    $out.Authenticated = $false
                    $out.AuthDetail    = $_.Exception.Message
                }
            } else {
                $out.AuthDetail = 'not tested (no credentials)'
            }
        } catch { }

        return $out
    })

    return $results
}

# ---- Show window -------------------------------------------------------------
try {
    Initialize-SettingsTab
    $window.ShowDialog() | Out-Null
} catch {
    [System.Windows.MessageBox]::Show(
        "Fatal error launching the window:`n`n$($_.Exception.Message)`n`nStack:`n$($_.ScriptStackTrace)",
        "Fatal error", 'OK', 'Error'
    ) | Out-Null
    throw
}



