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
    SubnetsFile        = Join-Path $WorkingDirectory 'subnets.txt'
}

# ---- XAML --------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Crestron Admin Bootstrap"
        Width="1100" Height="750"
        MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen">
    <DockPanel LastChildFill="True">

        <!-- Status bar (docked bottom) -->
        <StatusBar DockPanel.Dock="Bottom" Height="28">
            <StatusBarItem>
                <TextBlock x:Name="StatusText" Text="Idle" />
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
                            <TextBlock DockPanel.Dock="Top" Text="Subnets (CIDR)" FontWeight="Bold" Margin="0,0,0,6" />

                            <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="ScanCidrInput" Grid.Column="0" Padding="4,2" VerticalContentAlignment="Center" />
                                <Button   x:Name="ScanAddCidr"  Grid.Column="1" Content="Add" Margin="6,0,0,0" Padding="10,2" />
                            </Grid>

                            <Button x:Name="ScanRemoveCidr" DockPanel.Dock="Bottom" Content="Remove Selected" Margin="0,6,0,0" Padding="10,2" />

                            <ListBox x:Name="ScanCidrList" SelectionMode="Extended" />
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
                            <TextBlock x:Name="ScanProgressText" Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#666" />
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
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="BlanketSummaryText" Grid.Column="0" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                                <CheckBox  x:Name="BlanketSelectAll"   Grid.Column="1" Content="Select all" IsChecked="True" />
                                <Button    x:Name="BlanketReloadButton" Grid.Column="2" Content="Add Devices..." Padding="10,2" Margin="8,0,0,0" />
                            </Grid>

                            <DataGrid x:Name="BlanketGrid"
                                      AutoGenerateColumns="False"
                                      CanUserAddRows="False"
                                      CanUserDeleteRows="False"
                                      HeadersVisibility="Column"
                                      GridLinesVisibility="Horizontal"
                                      SelectionMode="Extended"
                                      AlternatingRowBackground="#F8F8F8">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Sel" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40" />
                                    <DataGridTextColumn Header="IP"        Binding="{Binding IP}"        Width="140" IsReadOnly="True" />
                                    <DataGridTextColumn Header="Status"   Binding="{Binding Status}"   Width="90"  IsReadOnly="True" />
                                    <DataGridTextColumn Header="Sections" Binding="{Binding Sections}" Width="200" IsReadOnly="True" />
                                    <DataGridTextColumn Header="Detail"   Binding="{Binding Detail}"   Width="*"   IsReadOnly="True" />
                                    <DataGridTextColumn Header="Time"     Binding="{Binding Timestamp}" Width="160" IsReadOnly="True" />
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <!-- Bottom: settings sections + apply -->
                    <Grid DockPanel.Dock="Bottom" Margin="0,0,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BlanketApplyButton"  Grid.Column="0" Content="Apply to Selected" Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="BlanketRebootButton" Grid.Column="1" Content="Reboot Selected" Padding="10,4" Margin="8,0,0,0" HorizontalAlignment="Left" />
                        <TextBlock x:Name="BlanketProgressText" Grid.Column="1" Margin="170,0,0,0" VerticalAlignment="Center" Foreground="#666" />
                        <Button x:Name="BlanketCancelButton" Grid.Column="2" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <!-- Middle (fills): the three settings sections -->
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
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

                            <!-- XiO Cloud -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                                <StackPanel>
                                    <CheckBox x:Name="CloudEnableBox" Content="Apply XiO Cloud toggle" FontWeight="Bold" />
                                    <StackPanel Orientation="Horizontal" Margin="20,8,0,0" IsEnabled="{Binding ElementName=CloudEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="CloudOnRadio"  GroupName="CloudRadios" Content="Enable XiO Cloud"  IsChecked="True" Margin="0,0,16,0" />
                                        <RadioButton x:Name="CloudOffRadio" GroupName="CloudRadios" Content="Disable XiO Cloud" />
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <!-- Auto-Update -->
                            <Border BorderBrush="#DDD" BorderThickness="1" Padding="10">
                                <StackPanel>
                                    <CheckBox x:Name="AutoUpdateEnableBox" Content="Apply Auto-Update toggle" FontWeight="Bold" />
                                    <StackPanel Orientation="Horizontal" Margin="20,8,0,0" IsEnabled="{Binding ElementName=AutoUpdateEnableBox, Path=IsChecked}">
                                        <RadioButton x:Name="AutoUpdateOnRadio"  GroupName="AutoUpdateRadios" Content="Enable Auto-Update"  IsChecked="True" Margin="0,0,16,0" />
                                        <RadioButton x:Name="AutoUpdateOffRadio" GroupName="AutoUpdateRadios" Content="Disable Auto-Update" />
                                    </StackPanel>
                                    <TextBlock Margin="20,4,0,0" Foreground="#888" FontSize="11"
                                               Text="On TouchPanel devices only the on/off flag is sent; schedule/manifest fields are touchscreen-incompatible and are not exposed in the GUI." />
                                </StackPanel>
                            </Border>

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
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <Button x:Name="PerDeviceApplyButton"   Grid.Column="0" Content="Apply Changes"       Padding="16,4" FontWeight="Bold" />
                        <Button x:Name="PerDeviceAddButton"     Grid.Column="1" Content="Add Devices..."      Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="PerDeviceRefreshButton" Grid.Column="2" Content="Fetch current state" Padding="10,4" Margin="8,0,0,0" />
                        <Button x:Name="PerDeviceRebootButton"  Grid.Column="3" Content="Reboot All Loaded"   Padding="10,4" Margin="8,0,0,0" />
                        <TextBlock x:Name="PerDeviceProgressText" Grid.Column="4" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#666" />
                        <Button x:Name="PerDeviceCancelButton"  Grid.Column="5" Content="Cancel" Padding="12,4" IsEnabled="False" />
                    </Grid>

                    <TextBlock DockPanel.Dock="Top" Margin="0,0,0,6" TextWrapping="Wrap" Foreground="#666" FontSize="11"
                               Text="Edit per-device values inline. IP changes are fire-and-forget — Success means the device acknowledged the change before its current TCP connection dropped, not that the new IP is reachable. Use the Verify tab afterwards to confirm." />

                    <Grid DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <TextBlock x:Name="PerDeviceSummaryText" Text="No devices loaded." Foreground="#666" VerticalAlignment="Center" />
                    </Grid>

                    <DataGrid x:Name="PerDeviceGrid"
                              AutoGenerateColumns="False"
                              CanUserAddRows="False"
                              CanUserDeleteRows="False"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              SelectionMode="Extended"
                              AlternatingRowBackground="#F8F8F8">
                        <DataGrid.Columns>
                            <DataGridTextColumn      Header="IP"          Binding="{Binding IP}"          Width="120" IsReadOnly="True" />
                            <DataGridTextColumn      Header="Model"       Binding="{Binding Model}"       Width="90"  IsReadOnly="True" />
                            <DataGridTextColumn      Header="Hostname"    Binding="{Binding CurrentHostname}" Width="170" IsReadOnly="True" />
                            <DataGridTextColumn      Header="NewHostname" Binding="{Binding NewHostname, UpdateSourceTrigger=PropertyChanged}" Width="170" />
                            <DataGridComboBoxColumn  Header="IPMode"      SelectedValueBinding="{Binding IPMode, UpdateSourceTrigger=PropertyChanged}" Width="80">
                                <DataGridComboBoxColumn.ItemsSource>
                                    <x:Array Type="sys:String" xmlns:sys="clr-namespace:System;assembly=mscorlib">
                                        <sys:String>Keep</sys:String>
                                        <sys:String>DHCP</sys:String>
                                        <sys:String>Static</sys:String>
                                    </x:Array>
                                </DataGridComboBoxColumn.ItemsSource>
                            </DataGridComboBoxColumn>
                            <DataGridTextColumn      Header="NewIP"       Binding="{Binding NewIP, UpdateSourceTrigger=PropertyChanged}"      Width="120" />
                            <DataGridTextColumn      Header="SubnetMask"  Binding="{Binding SubnetMask, UpdateSourceTrigger=PropertyChanged}" Width="120" />
                            <DataGridTextColumn      Header="Gateway"     Binding="{Binding Gateway, UpdateSourceTrigger=PropertyChanged}"    Width="120" />
                            <DataGridTextColumn      Header="DNS1"        Binding="{Binding PrimaryDns, UpdateSourceTrigger=PropertyChanged}" Width="100" />
                            <DataGridTextColumn      Header="DNS2"        Binding="{Binding SecondaryDns, UpdateSourceTrigger=PropertyChanged}" Width="100" />
                            <DataGridCheckBoxColumn  Header="WiFi Off"    Binding="{Binding DisableWifi, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="60" />
                            <DataGridTextColumn      Header="Status"      Binding="{Binding Status}"     Width="80"  IsReadOnly="True" />
                            <DataGridTextColumn      Header="Detail"      Binding="{Binding Detail}"     Width="*"   IsReadOnly="True" />
                        </DataGrid.Columns>
                    </DataGrid>

                </DockPanel>
            </TabItem>
            <TabItem Header="Verify" x:Name="VerifyTab">
                <DockPanel Margin="8">

                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
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
                  'ProvisionTab','ProvisionStartButton','ProvisionReloadButton',
                  'ProvisionCancelButton','ProvisionProgressText',
                  'ProvisionGrid','ProvisionSelectAll','ProvisionSummaryText',
                  'VerifyTab','VerifyStartButton','VerifyReloadButton',
                  'VerifyCancelButton','VerifyProgressText',
                  'VerifyGrid','VerifySelectAll','VerifySummaryText',
                  'BlanketTab','BlanketGrid','BlanketSelectAll','BlanketSummaryText',
                  'BlanketReloadButton','BlanketApplyButton','BlanketCancelButton','BlanketProgressText',
                  'NtpEnableBox','NtpServerBox','NtpTimeZoneBox',
                  'CloudEnableBox','CloudOnRadio','CloudOffRadio',
                  'AutoUpdateEnableBox','AutoUpdateOnRadio','AutoUpdateOffRadio',
                  'PerDeviceTab','PerDeviceGrid','PerDeviceSummaryText',
                  'PerDeviceApplyButton','PerDeviceRefreshButton','PerDeviceAddButton',
                  'PerDeviceCancelButton','PerDeviceProgressText',
                  'ProvisionRebootButton','BlanketRebootButton','PerDeviceRebootButton',
                  'WorkflowTab','WorkflowStartButton','WorkflowContinueButton','WorkflowCancelButton',
                  'WorkflowStatusText','WorkflowStepsList',
                  'WorkflowRebootPanel','WorkflowCountdownText','WorkflowOnlineText','WorkflowRebootGrid') {
    $Script:UI[$name] = $window.FindName($name)
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
    if ($null -ne $Script:AppState.Credential) { return $Script:AppState.Credential }
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
        <TextBlock Grid.Row="0" Text="Username"   Margin="0,0,0,2" />
        <TextBox  x:Name="UserBox" Grid.Row="1" Padding="4,2" />
        <TextBlock Grid.Row="2" Text="Password"   Margin="0,8,0,2" />
        <PasswordBox x:Name="PassBox" Grid.Row="3" Padding="4,2" />
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="CancelBtn" Content="Cancel" Padding="14,4" Margin="0,0,8,0" />
            <Button x:Name="OkBtn"     Content="OK"     Padding="14,4" IsDefault="True" />
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

    $script:_credResult = $null
    $okBtn.Add_Click({
        if ($userBox.Text -and $passBox.Password) {
            $sec = ConvertTo-SecureString $passBox.Password -AsPlainText -Force
            $script:_credResult = [pscredential]::new($userBox.Text, $sec)
            $dlg.DialogResult = $true
            $dlg.Close()
        }
    })
    $cancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $dlg.Owner = $window
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
$Script:UI.ScanCidrList.ItemsSource    = $Script:ScanState.Cidrs
$Script:UI.ScanResultsGrid.ItemsSource = $Script:ScanState.Results

# Seed CIDRs: load from existing subnets.txt or pre-fill 172.22.0.0/24
function Initialize-ScanCidrs {
    $Script:ScanState.Cidrs.Clear()
    if (Test-Path $Script:AppState.SubnetsFile) {
        $loaded = Get-Content $Script:AppState.SubnetsFile |
            ForEach-Object { ($_ -split '#')[0].Trim() } |
            Where-Object   { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' }
        foreach ($c in $loaded) { [void]$Script:ScanState.Cidrs.Add($c) }
    }
    if ($Script:ScanState.Cidrs.Count -eq 0) {
        [void]$Script:ScanState.Cidrs.Add('172.22.0.0/24')
    }
}

function Save-ScanCidrs {
    $Script:ScanState.Cidrs | Set-Content -Path $Script:AppState.SubnetsFile -Encoding UTF8
}

function Add-ScanCidr {
    $entry = $Script:UI.ScanCidrInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($entry)) { return }
    if ($entry -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') {
        [System.Windows.MessageBox]::Show("Not a valid CIDR (expected like 10.10.20.0/24).", "Invalid CIDR", 'OK', 'Warning') | Out-Null
        return
    }
    if ($Script:ScanState.Cidrs -contains $entry) {
        Update-Status "CIDR already in list: $entry"
        return
    }
    [void]$Script:ScanState.Cidrs.Add($entry)
    $Script:UI.ScanCidrInput.Text = ''
    Save-ScanCidrs
}

function Remove-ScanCidr {
    $sel = @($Script:UI.ScanCidrList.SelectedItems)
    foreach ($s in $sel) { [void]$Script:ScanState.Cidrs.Remove($s) }
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
    if ($Script:ScanState.Cidrs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Add at least one CIDR to the list before scanning.", "Nothing to scan", 'OK', 'Warning') | Out-Null
        return
    }
    Save-ScanCidrs

    $Script:ScanState.Results.Clear()
    Update-ScanSummary
    $Script:UI.ScanProgressText.Text = 'Probing...'
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

    $cred = Get-CachedCredential
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
                $queue.Enqueue([pscustomobject]@{
                    __result  = $true
                    IP        = $r.IP
                    Status    = "$($r.Status)"
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

function Update-BlanketSummary {
    $count    = $Script:BlanketState.Rows.Count
    $selected = ($Script:BlanketState.Rows | Where-Object Selected).Count
    $ok       = ($Script:BlanketState.Rows | Where-Object { $_.Status -eq 'OK' }).Count
    $fail     = ($Script:BlanketState.Rows | Where-Object { $_.Status -and $_.Status -notin 'OK','Pending','Working' }).Count
    $Script:UI.BlanketSummaryText.Text = "Loaded $count device(s). Selected: $selected. OK: $ok. Failed: $fail."
}

function Set-BlanketControls ($isRunning) {
    $Script:BlanketState.IsRunning            = $isRunning
    $Script:UI.BlanketApplyButton.IsEnabled   = -not $isRunning
    $Script:UI.BlanketReloadButton.IsEnabled  = -not $isRunning
    $Script:UI.BlanketCancelButton.IsEnabled  = $isRunning
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
            Selected  = $true
            IP        = $s.IP
            Status    = ''
            Sections  = ''
            Detail    = ''
            Timestamp = ''
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
        Select-Object IP, Status, Sections, Detail, Timestamp |
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
    $applyAuto   = [bool]$Script:UI.AutoUpdateEnableBox.IsChecked
    if (-not ($applyNtp -or $applyCloud -or $applyAuto)) {
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
        $ntp = @{ TimeZone = $tzItem.Code; NtpServer = $server; NtpEnabled = $true }
    }
    $cloud = $null
    if ($applyCloud) {
        $cloud = [bool]$Script:UI.CloudOnRadio.IsChecked
    }
    $autoUpdate = $null
    if ($applyAuto) {
        $autoUpdate = @{ Enabled = [bool]$Script:UI.AutoUpdateOnRadio.IsChecked }
    }

    # Credentials
    $cred = Get-CachedCredential
    if (-not $cred) { Update-Status 'Apply cancelled (no credentials).'; return }

    # Summary + confirm
    $bits = @()
    if ($applyNtp)    { $bits += "NTP=$($ntp.NtpServer)/$($ntp.TimeZone)" }
    if ($applyCloud)  { $bits += "Cloud=$(if ($cloud) {'ON'} else {'OFF'})" }
    if ($applyAuto)   { $bits += "AutoUpdate=$(if ($autoUpdate.Enabled) {'ON'} else {'OFF'})" }
    $msg = "Apply [$($bits -join ', ')] to $($selectedIPs.Count) device(s) as '$($cred.UserName)'?"
    $confirm = [System.Windows.MessageBox]::Show($msg, "Confirm apply", 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { Update-Status 'Apply cancelled.'; return }

    # Mark selected rows
    foreach ($ip in $selectedIPs) {
        $row = $Script:BlanketState.RowsByIP[$ip]
        if ($row) {
            $row.Status    = 'Pending'
            $row.Sections  = ''
            $row.Detail    = ''
            $row.Timestamp = ''
        }
    }
    $Script:UI.BlanketGrid.Items.Refresh()
    $Script:UI.BlanketProgressText.Text = "Applying to $($selectedIPs.Count) device(s)..."
    Set-BlanketControls $true
    Update-Status "Applying blanket settings to $($selectedIPs.Count) device(s)..."

    $queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $doneRef = [ref]$false

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('queue',     $queue)
    $rs.SessionStateProxy.SetVariable('doneRef',   $doneRef)
    $rs.SessionStateProxy.SetVariable('ips',       $selectedIPs)
    $rs.SessionStateProxy.SetVariable('userName',  $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass',  $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('ntp',       $ntp)
    $rs.SessionStateProxy.SetVariable('cloudArg',  $cloud)
    $rs.SessionStateProxy.SetVariable('autoUpdate',$autoUpdate)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            Import-Module CrestronAdminBootstrap -Force -ErrorAction Stop
            $sec     = ConvertTo-SecureString $userPass -AsPlainText -Force
            $credObj = [pscredential]::new($userName, $sec)

            # Resolve the module's manifest path once on the outer runspace; pass it
            # into each parallel worker so they import by absolute path. Avoids
            # PSModulePath quirks in nested runspaces.
            $modManifest = (Get-Module CrestronAdminBootstrap).Path
            if (-not $modManifest) {
                $modManifest = (Get-Module -ListAvailable CrestronAdminBootstrap | Sort-Object Version -Descending | Select-Object -First 1).Path
            }
            if (-not $modManifest -or -not (Test-Path $modManifest)) {
                throw "Could not locate CrestronAdminBootstrap module manifest. Reinstall the module."
            }

            $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip       = $_
                $q        = $using:queue
                $cred     = $using:credObj
                $ntpArg   = $using:ntp
                $cArg     = $using:cloudArg
                $auArg    = $using:autoUpdate
                $manifest = $using:modManifest

                $q.Enqueue([pscustomobject]@{ __progress=$true; IP=$ip; Status='Working' })

                try {
                    if (-not $manifest -or -not (Test-Path $manifest)) { throw "Manifest path missing or not found: '$manifest'" }
                    Import-Module $manifest -Force -ErrorAction Stop
                    if (-not (Get-Command Connect-CrestronDevice -ErrorAction SilentlyContinue)) { throw "Import-Module ran but Connect-CrestronDevice not exposed. Module path: '$manifest'. Loaded modules: $((Get-Module).Name -join ', ')" }
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred
                    try {
                        $callArgs = @{ Session = $sess }
                        if ($ntpArg)            { $callArgs.Ntp        = $ntpArg }
                        if ($null -ne $cArg)    { $callArgs.Cloud      = $cArg }
                        if ($auArg)             { $callArgs.AutoUpdate = $auArg }
                        $r = Set-CrestronSettings @callArgs
                        $q.Enqueue([pscustomobject]@{
                            __result  = $true
                            IP        = $ip
                            Status    = $(if ($r.Success) { 'OK' } else { "$($r.Status)" })
                            Sections  = ($r.AppliedSections -join ', ')
                            Detail    = ($r.SectionResults | ForEach-Object { "$($_.Path):$($_.StatusInfo)" }) -join '; '
                            Timestamp = $r.Timestamp
                        })
                    } finally {
                        if ($sess) { Disconnect-CrestronDevice -Session $sess }
                    }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        __result  = $true
                        IP        = $ip
                        Status    = 'Error'
                        Sections  = ''
                        Detail    = "ERROR: $($_.Exception.Message)"
                        Timestamp = (Get-Date).ToString('s')
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally {
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
            $row.Status = $item.Status
            if (-not $item.__progress) {
                $row.Sections  = $item.Sections
                $row.Detail    = $item.Detail
                $row.Timestamp = $item.Timestamp
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
$Script:UI.BlanketReloadButton.Add_Click({ Load-BlanketFromProvision })
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

$Script:UI.BlanketGrid.Add_CellEditEnding({ Update-BlanketSummary })

$window.Add_Closed({ Stop-BlanketRunspace })

# =============================================================================
# Per-Device tab
# =============================================================================

$Script:PerDeviceState = [pscustomobject]@{
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
$Script:UI.PerDeviceGrid.ItemsSource = $Script:PerDeviceState.Rows

function Update-PerDeviceSummary {
    $count    = $Script:PerDeviceState.Rows.Count
    $edited   = ($Script:PerDeviceState.Rows | Where-Object {
        $_.NewHostname -or $_.IPMode -ne 'Keep' -or $_.DisableWifi
    }).Count
    $ok       = ($Script:PerDeviceState.Rows | Where-Object Status -eq 'OK').Count
    $fail     = ($Script:PerDeviceState.Rows | Where-Object { $_.Status -and $_.Status -notin 'OK','Pending','Working' }).Count
    $Script:UI.PerDeviceSummaryText.Text = "Loaded $count device(s). With changes: $edited. OK: $ok. Failed: $fail."
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
            IP              = $s.IP
            Model           = ''
            CurrentHostname = ''
            CurrentDhcp     = $null
            CurrentWifi     = $null
            HasWifi         = $true   # assume true until DeviceInfo proves otherwise
            NewHostname     = ''
            IPMode          = 'Keep'
            NewIP           = ''
            SubnetMask      = ''
            Gateway         = ''
            PrimaryDns      = ''
            SecondaryDns    = ''
            DisableWifi     = $false
            Status          = ''
            Detail          = ''
            Timestamp       = ''
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
        Select-Object IP, Model, CurrentHostname, NewHostname, IPMode, NewIP, SubnetMask, Gateway,
                      PrimaryDns, SecondaryDns, DisableWifi, Status, Detail, Timestamp |
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
    if (-not $cred) { Update-Status 'Fetch cancelled (no credentials).'; return }

    $Script:UI.PerDeviceProgressText.Text = "Fetching state for $($ips.Count) device(s)..."
    Set-PerDeviceControls $true
    Update-Status "Fetching device state..."

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
    $rs.SessionStateProxy.SetVariable('ips',      $ips)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $ips | ForEach-Object -ThrottleLimit 16 -Parallel {
                $ip   = $_
                $q    = $using:queue
                $u    = $using:userName
                $p    = $using:userPass
                $mp   = $using:manifest
                try {
                    if (-not $mp -or -not (Test-Path $mp)) { throw "Module manifest path missing: '$mp'" }
                    Import-Module $mp -Force -ErrorAction Stop
                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $ip -Credential $cred
                    try {
                        $state = Get-CrestronDeviceState -Session $sess
                            $q.Enqueue([pscustomobject]@{
                            IP              = $ip
                            Model           = $sess.Model
                            CurrentHostname = $state.Hostname
                            CurrentDhcp     = $state.EthernetLanDhcp
                            CurrentWifi     = $state.WifiEnabled
                            HasWifi         = $state.HasWifi
                            Detail          = "OK"
                        })
                    } finally { Disconnect-CrestronDevice -Session $sess }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        IP = $ip
                        Detail = "ERROR: $($_.Exception.Message)"
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally { $doneRef.Value = $true }
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
            if (-not $row) { continue }
            if ($item.Model) {
                $row.Model           = $item.Model
                $row.CurrentHostname = $item.CurrentHostname
                $row.CurrentDhcp     = $item.CurrentDhcp
                $row.CurrentWifi     = $item.CurrentWifi
                $row.HasWifi         = [bool]$item.HasWifi
                if (-not $row.Status) { $row.Status = '' }
            }
            $row.Detail = $item.Detail
        }
        $Script:UI.PerDeviceGrid.Items.Refresh()
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
    if ($row.NewHostname -and ($row.NewHostname -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$')) {
        return "Invalid hostname '$($row.NewHostname)'"
    }
    if ($row.IPMode -eq 'Static') {
        $ipPattern = '^(\d{1,3}\.){3}\d{1,3}$'
        if ($row.NewIP      -notmatch $ipPattern) { return "Invalid NewIP" }
        if ($row.SubnetMask -notmatch $ipPattern) { return "Invalid SubnetMask" }
        if ($row.Gateway    -notmatch $ipPattern) { return "Invalid Gateway" }
        if ($row.PrimaryDns   -and $row.PrimaryDns   -notmatch $ipPattern) { return "Invalid DNS1" }
        if ($row.SecondaryDns -and $row.SecondaryDns -notmatch $ipPattern) { return "Invalid DNS2" }
    }
    if ($row.DisableWifi -and -not $row.HasWifi) {
        return "This device has no WiFi adapter (uncheck 'WiFi Off')"
    }
    return $null
}

function Start-PerDeviceApply {
    if ($Script:PerDeviceState.IsRunning) { return }

    # Find rows with any change
    $rowsToApply = @($Script:PerDeviceState.Rows | Where-Object {
        $_.NewHostname -or $_.IPMode -ne 'Keep' -or $_.DisableWifi
    })
    if ($rowsToApply.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No rows have any pending changes.", "Nothing to apply", 'OK', 'Warning') | Out-Null
        return
    }

    # Validate
    $errors = @()
    foreach ($r in $rowsToApply) {
        $err = Test-PerDeviceRow $r
        if ($err) { $errors += "$($r.IP): $err" }
    }
    if ($errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show("Validation failed:`n`n$($errors -join "`n")", "Fix errors first", 'OK', 'Error') | Out-Null
        return
    }

    $cred = Get-CachedCredential
    if (-not $cred) { Update-Status 'Apply cancelled (no credentials).'; return }

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
        if ($ans -ne 'Yes') { Update-Status 'Apply cancelled.'; return }
    }

    $msg = "Apply changes to $($rowsToApply.Count) device(s) as '$($cred.UserName)'?`n`nIP changes are fire-and-forget — Success means the device acknowledged the change, not that it came back on the new IP."
    $ans = [System.Windows.MessageBox]::Show($msg, "Confirm per-device apply", 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Update-Status 'Apply cancelled.'; return }

    foreach ($r in $rowsToApply) {
        $r.Status    = 'Pending'
        $r.Detail    = ''
        $r.Timestamp = ''
    }
    $Script:UI.PerDeviceGrid.Items.Refresh()
    $Script:UI.PerDeviceProgressText.Text = "Applying to $($rowsToApply.Count) device(s)..."
    Set-PerDeviceControls $true
    Update-Status "Applying per-device changes to $($rowsToApply.Count) device(s)..."

    # Serialize rows as plain hashtables so they cross the runspace boundary
    $rowData = $rowsToApply | ForEach-Object {
        @{
            IP           = $_.IP
            NewHostname  = $_.NewHostname
            IPMode       = $_.IPMode
            NewIP        = $_.NewIP
            SubnetMask   = $_.SubnetMask
            Gateway      = $_.Gateway
            PrimaryDns   = $_.PrimaryDns
            SecondaryDns = $_.SecondaryDns
            DisableWifi  = [bool]$_.DisableWifi
        }
    }

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
    $rs.SessionStateProxy.SetVariable('rows',     $rowData)
    $rs.SessionStateProxy.SetVariable('userName', $cred.UserName)
    $rs.SessionStateProxy.SetVariable('userPass', $cred.GetNetworkCredential().Password)
    $rs.SessionStateProxy.SetVariable('manifest', $modManifest)

    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $rows | ForEach-Object -ThrottleLimit 16 -Parallel {
                $row  = $_
                $q    = $using:queue
                $u    = $using:userName
                $p    = $using:userPass
                $mp   = $using:manifest

                $q.Enqueue([pscustomobject]@{ __progress=$true; IP=$row.IP; Status='Working' })

                try {
                    if (-not $mp -or -not (Test-Path $mp)) { throw "Module manifest path missing: '$mp'" }
                    Import-Module $mp -Force -ErrorAction Stop
                    $sec  = ConvertTo-SecureString $p -AsPlainText -Force
                    $cred = [pscredential]::new($u, $sec)
                    $sess = Connect-CrestronDevice -IP $row.IP -Credential $cred

                    $stepResults = @()
                    $allOk = $true

                    try {
                        if ($row.NewHostname) {
                            $r1 = Set-CrestronHostname -Session $sess -Hostname $row.NewHostname
                            $stepResults += "Hostname=$(if($r1.Success){'OK'}else{$r1.Status})"
                            if (-not $r1.Success) { $allOk = $false }
                        }
                        if ($row.IPMode -in 'DHCP','Static') {
                            $netArgs = @{ Session = $sess; IPMode = $row.IPMode }
                            if ($row.IPMode -eq 'Static') {
                                $netArgs.NewIP        = $row.NewIP
                                $netArgs.SubnetMask   = $row.SubnetMask
                                $netArgs.Gateway      = $row.Gateway
                                if ($row.PrimaryDns)   { $netArgs.PrimaryDns   = $row.PrimaryDns }
                                if ($row.SecondaryDns) { $netArgs.SecondaryDns = $row.SecondaryDns }
                            }
                            if ($row.DisableWifi)     { $netArgs.DisableWifi   = $true }
                            $r2 = Set-CrestronNetwork @netArgs
                            $stepResults += "Network=$(if($r2.Success){'OK'}else{$r2.Status})"
                            if (-not $r2.Success) { $allOk = $false }
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

                        $q.Enqueue([pscustomobject]@{
                            __result   = $true
                            IP         = $row.IP
                            Status     = if ($allOk) { 'OK' } else { 'Partial' }
                            Detail     = ($stepResults -join '; ')
                            Timestamp  = (Get-Date).ToString('s')
                        })
                    } finally {
                        # Session may be invalid after IP change; Disconnect just cleans local jar
                        try { Disconnect-CrestronDevice -Session $sess } catch { }
                    }
                } catch {
                    $q.Enqueue([pscustomobject]@{
                        __result  = $true
                        IP        = $row.IP
                        Status    = 'Error'
                        Detail    = "ERROR: $($_.Exception.Message)"
                        Timestamp = (Get-Date).ToString('s')
                    })
                }
            }
        } catch {
            $queue.Enqueue([pscustomobject]@{ __error = $_.Exception.Message })
        } finally { $doneRef.Value = $true }
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
                $row.Detail    = $item.Detail
                $row.Timestamp = $item.Timestamp
            }
        }
        $Script:UI.PerDeviceGrid.Items.Refresh()
        Update-PerDeviceSummary

        if ($Script:PerDeviceState.DoneRef.Value -and $Script:PerDeviceState.Queue.IsEmpty) {
            Stop-PerDeviceRunspace
            Set-PerDeviceControls $false
            Save-PerDeviceCsv
            $ok = ($Script:PerDeviceState.Rows | Where-Object Status -eq 'OK').Count
            $Script:UI.PerDeviceProgressText.Text = "Done. $ok device(s) OK."
            Update-Status "Per-device apply complete. $ok OK. Saved $($Script:AppState.PerDeviceCsv)"
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

$Script:UI.PerDeviceGrid.Add_CellEditEnding({ Update-PerDeviceSummary })

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

function Invoke-RebootBulk ($ips, $statusCallback) {
    if ($ips.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No devices to reboot.", "Nothing selected", 'OK', 'Warning') | Out-Null
        return
    }

    $cred = Get-CachedCredential
    if (-not $cred) { Update-Status 'Reboot cancelled (no credentials).'; return }

    $msg = "Reboot $($ips.Count) device(s)?`n`nThis will disconnect each device immediately. Pending settings changes will take effect after the reboot."
    $ans = [System.Windows.MessageBox]::Show($msg, "Confirm reboot", 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Update-Status 'Reboot cancelled.'; return }

    Update-Status "Rebooting $($ips.Count) device(s)..."

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
    $rs.SessionStateProxy.SetVariable('ips',      $ips)
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
            if ($statusCallback) { & $statusCallback $item }
        }
        if ($Script:RebootState.DoneRef.Value -and $Script:RebootState.Queue.IsEmpty) {
            Stop-RebootRunspace
            Update-Status "Reboot complete."
        }
    })
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
    $ips = @($Script:BlanketState.Rows | Where-Object Selected | Select-Object -ExpandProperty IP)
    Invoke-RebootBulk $ips {
        param($item)
        $row = $Script:BlanketState.RowsByIP[$item.IP]
        if ($row) {
            $row.Status    = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Detail    = $item.Detail
            $row.Timestamp = (Get-Date).ToString('s')
        }
        $Script:UI.BlanketGrid.Items.Refresh()
    }
})

# Per-Device tab — reboot all loaded
$Script:UI.PerDeviceRebootButton.Add_Click({
    $ips = @($Script:PerDeviceState.Rows | Select-Object -ExpandProperty IP)
    Invoke-RebootBulk $ips {
        param($item)
        $row = $Script:PerDeviceState.RowsByIP[$item.IP]
        if ($row) {
            $row.Status    = if ($item.Success -eq 'True') { 'Rebooting' } else { 'RebootFail' }
            $row.Detail    = $item.Detail
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
        Set-WorkflowStep 0 '🔄' 'Probing CIDRs...'
        $Script:UI.MainTabs.SelectedIndex = 1  # Scan tab
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
            Invoke-RebootBulk $rebootIps { param($item) }
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

        # Verify
        $Script:UI.WorkflowStatusText.Text = 'Verifying...'
        $Script:UI.MainTabs.SelectedIndex = 5  # Verify
        Load-VerifyFromProvision
        Start-Verify
        Wait-ForInnerTab { $Script:VerifyState.IsRunning }
        if ($Script:WorkflowState.Cancelled) { throw 'Cancelled by user.' }
        $verified = ($Script:VerifyState.Rows | Where-Object Verified -eq 'True').Count
        Set-WorkflowStep 5 '✅' "Wait: $online/$total online. Verify: $verified/$total past bootup."

        # Hide the reboot panel
        $Script:UI.WorkflowRebootPanel.Visibility = 'Collapsed'
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
    grid's row collection. $target is the row dict (e.g. $Script:PerDeviceState.RowsByIP).
    #>
    param(
        [System.Collections.ObjectModel.ObservableCollection[object]]$Rows,
        [hashtable]$RowsByIP,
        [scriptblock]$RowFactory   # called as { param($ip) ; ... } to make a new row
    )

    $candidateIps = Show-AddDevicesDialog
    if (-not $candidateIps -or $candidateIps.Count -eq 0) { return }

    # Filter out IPs already in the grid
    $newIps = @($candidateIps | Where-Object { -not $RowsByIP.ContainsKey($_) })
    $skipped = $candidateIps.Count - $newIps.Count

    if ($newIps.Count -eq 0) {
        [System.Windows.MessageBox]::Show("All $($candidateIps.Count) IP(s) are already loaded.", "Nothing to add", 'OK', 'Information') | Out-Null
        return
    }

    Update-Status "Probing $($newIps.Count) candidate IP(s)..."
    $probeResults  = Find-DevicesReachable -Ips $newIps -Credential $Script:AppState.Credential
    $reachableObjs = @($probeResults | Where-Object Reachable)
    if ($reachableObjs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No Crestron devices responded among $($newIps.Count) IP(s).", "No devices found", 'OK', 'Warning') | Out-Null
        Update-Status "No responsive Crestron devices found."
        return
    }

    $authOk   = @($reachableObjs | Where-Object Authenticated)
    $authFail = @($reachableObjs | Where-Object { -not $_.Authenticated -and $Script:AppState.Credential })
    $noTested = @($reachableObjs | Where-Object { -not $Script:AppState.Credential })

    foreach ($obj in $reachableObjs) {
        $row = & $RowFactory $obj.IP
        # If the row has a Detail field, surface auth failure there so the tech sees it
        if ($null -ne $row.PSObject.Properties['Detail']) {
            if ($Script:AppState.Credential) {
                if ($obj.Authenticated) {
                    $row.Detail = 'Auth OK'
                } else {
                    $row.Detail = "Auth FAILED: $($obj.AuthDetail)"
                    if ($null -ne $row.PSObject.Properties['Status']) { $row.Status = 'AuthFail' }
                }
            }
        }
        $Rows.Add($row)
        $RowsByIP[$obj.IP] = $row
    }

    $bits = @()
    $bits += "Added $($reachableObjs.Count) device(s)"
    if ($authOk.Count -gt 0)   { $bits += "Auth OK: $($authOk.Count)" }
    if ($authFail.Count -gt 0) { $bits += "Auth failed: $($authFail.Count)" }
    if ($noTested.Count -gt 0) { $bits += "Not tested (no creds): $($noTested.Count)" }
    if ($skipped -gt 0)        { $bits += "Skipped (already loaded): $skipped" }
    if ($reachableObjs.Count -lt $newIps.Count) {
        $bits += "Unreachable: $($newIps.Count - $reachableObjs.Count)"
    }
    Update-Status ($bits -join '. ')

    if ($authFail.Count -gt 0) {
        $sample = $authFail | Select-Object -First 3
        $sampleDetail = ($sample | ForEach-Object { "  $($_.IP):  $($_.AuthDetail)" }) -join "`n"
        $failedIps = ($authFail | Select-Object -ExpandProperty IP) -join ', '
        [System.Windows.MessageBox]::Show(
            "$($authFail.Count) device(s) failed authentication with the cached credentials:`n`n$failedIps`n`nFirst few errors:`n$sampleDetail`n`nIf the credentials work in the web UI but fail here, copy the error message and share it.",
            "Some devices failed authentication",
            'OK', 'Warning'
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
                IP              = $ip
                Model           = ''
                CurrentHostname = ''
                CurrentDhcp     = $null
                CurrentWifi     = $null
                HasWifi         = $true
                NewHostname     = ''
                IPMode          = 'Keep'
                NewIP           = ''
                SubnetMask      = ''
                Gateway         = ''
                PrimaryDns      = ''
                SecondaryDns    = ''
                DisableWifi     = $false
                Status          = ''
                Detail          = ''
                Timestamp       = ''
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

# Repurpose the existing Blanket "Reload" button to open the same dialog.
# We swap the click handler at runtime — replaces the previous "reload from CSV" behavior.
# (cannot remove the old Click handler at runtime; the previous Load-BlanketFromProvision call fires too, which is harmless)

$Script:UI.BlanketReloadButton.Add_Click({
    Add-DevicesToGrid `
        -Rows $Script:BlanketState.Rows `
        -RowsByIP $Script:BlanketState.RowsByIP `
        -RowFactory {
            param($ip)
            [pscustomobject]@{
                Selected  = $true
                IP        = $ip
                Status    = ''
                Sections  = ''
                Detail    = ''
                Timestamp = ''
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

function Show-AddDevicesDialog {
    <#
    Opens a modal with 3 tabs (CIDR scan / IP list / Provisioning CSV) and
    returns an array of IP strings to add. Returns @() if the user cancelled.
    #>
    [xml]$dxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Devices" Width="540" Height="430"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <DockPanel Margin="12">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="AddCancelBtn" Content="Cancel" Padding="14,4" Margin="0,0,8,0" />
            <Button x:Name="AddOkBtn"     Content="Discover and Add" Padding="14,4" IsDefault="True" />
        </StackPanel>

        <TabControl x:Name="AddTabs">
            <TabItem Header="CIDR Scan">
                <DockPanel Margin="8">
                    <TextBlock DockPanel.Dock="Top" Text="Enter one or more CIDR ranges (one per line)." Foreground="#666" Margin="0,0,0,4" />
                    <TextBox x:Name="AddCidrBox" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" FontFamily="Consolas"
                             Text="172.22.0.0/24" />
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
    $cidrBox    = $dlg.FindName('AddCidrBox')
    $ipsBox     = $dlg.FindName('AddIpsBox')
    $csvSummary = $dlg.FindName('AddCsvSummary')
    $okBtn      = $dlg.FindName('AddOkBtn')
    $cancelBtn  = $dlg.FindName('AddCancelBtn')

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
                $lines = $cidrBox.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' }
                if ($lines.Count -eq 0) {
                    [System.Windows.MessageBox]::Show("No valid CIDR ranges entered.", "Invalid input", 'OK', 'Warning') | Out-Null
                    return
                }
                # Expand CIDRs to individual IPs
                foreach ($cidr in $lines) {
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
    $window.ShowDialog() | Out-Null
} catch {
    [System.Windows.MessageBox]::Show(
        "Fatal error launching the window:`n`n$($_.Exception.Message)`n`nStack:`n$($_.ScriptStackTrace)",
        "Fatal error", 'OK', 'Error'
    ) | Out-Null
    throw
}



