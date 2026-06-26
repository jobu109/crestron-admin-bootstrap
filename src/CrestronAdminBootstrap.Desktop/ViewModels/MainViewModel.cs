using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CrestronAdminBootstrap.Desktop.Models;
using CrestronAdminBootstrap.Desktop.Services;

namespace CrestronAdminBootstrap.Desktop.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private static readonly Regex CidrPattern = new(@"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$", RegexOptions.Compiled);
    private static readonly TimeSpan WorkflowRebootWait = TimeSpan.FromMinutes(4);

    private enum WorkflowWaitStage
    {
        None,
        Blanket,
        PerDevice
    }

    private readonly PowerShellBackend _backend;
    private CancellationTokenSource? _scanCancellation;
    private CancellationTokenSource? _workflowRebootWaitCancellation;
    private string _newSubnet = "";
    private string _blanketDeviceInput = "";
    private string _perDeviceInput = "";
    private string _statusText = "Ready.";
    private string _progressText = "No scan running.";
    private string _workflowStatus = "Workflow not running.";
    private string _workflowContinueText = "Continue Workflow";
    private string _workflowRebootCountdown = "";
    private string _settingsDefaultUsername = "";
    private string _settingsDefaultPassword = "";
    private string _settingsConfirmPassword = "";
    private string _settingsMostUsedSubnets = "";
    private string _settingsStatus = "";
    private int _mainTabIndex;
    private bool _isBusy;
    private bool _isWorkflowRunning;
    private bool _isWorkflowWaiting;
    private bool _isWorkflowRebootWaiting;
    private bool _workflowCancelRequested;
    private bool _settingsDarkMode = true;
    private bool _settingsHasSavedPassword;

    private sealed record ProvisionCredentialInput(string Username, string Password);
    private string? _sessionUsername;
    private string? _sessionPassword;
    private WorkflowWaitStage _workflowWaitStage = WorkflowWaitStage.None;
    private bool _applyNtp;
    private string _ntpServer = "time.google.com";
    private string _timeZoneCode = "010";
    private bool _applyCloud;
    private bool _cloudEnabled = true;
    private bool _applyFusion;
    private bool _fusionEnabled = true;
    private bool _applyAutoUpdate;
    private bool _autoUpdateEnabled = true;
    private bool _applyDisplay;
    private bool _autoBrightnessEnabled = true;
    private int _brightness = 70;
    private bool _screensaverEnabled = true;
    private int _standbyTimeout = 60;
    private bool _toolbarEnabled = true;
    private bool _applyAvFramework;
    private bool _avFrameworkEnabled = true;
    private bool _applyInputHdcp;
    private string _inputHdcpMode = "Auto";
    private bool _applyOutputHdcp;
    private string _outputHdcpMode = "Auto";
    private bool _applyOutputResolution;
    private string _outputResolution = "Auto";
    private bool _applyGlobalEdid;
    private string _globalEdidName = "";
    private string _globalEdidType = "System";

    public MainViewModel(PowerShellBackend backend)
    {
        _backend = backend;

        StartWorkflowCommand = new AsyncRelayCommand(_ => StartWorkflowAsync(), () => !IsBusy && !IsWorkflowRunning && Subnets.Count > 0);
        ContinueWorkflowCommand = new AsyncRelayCommand(_ => ContinueWorkflowAsync(), () => !IsBusy && IsWorkflowRunning && IsWorkflowWaiting);
        CancelWorkflowCommand = new RelayCommand(CancelWorkflow, () => IsWorkflowRunning);
        SkipWorkflowRebootWaitCommand = new RelayCommand(SkipWorkflowRebootWait, () => IsWorkflowRebootWaiting);
        StartScanCommand = new AsyncRelayCommand(_ => StartScanAsync(), CanStartScan);
        CancelScanCommand = new RelayCommand(CancelScan, () => IsBusy);
        AddSubnetCommand = new RelayCommand(AddSubnet, () => !string.IsNullOrWhiteSpace(NewSubnet) && !IsBusy);
        SelectAllSubnetsCommand = new RelayCommand(() => SetAllSubnets(true), () => !IsBusy);
        DeselectAllSubnetsCommand = new RelayCommand(() => SetAllSubnets(false), () => !IsBusy);
        LoadProvisionFromScanCommand = new RelayCommand(LoadProvisionFromScan, () => !IsBusy && ScanResults.Count > 0);
        ProvisionSelectedCommand = new AsyncRelayCommand(_ => ProvisionSelectedAsync(), CanProvisionSelected);
        RebootSelectedProvisionCommand = new AsyncRelayCommand(_ => RebootSelectedProvisionAsync(), () => !IsBusy && !IsWorkflowRebootWaiting && ProvisionRows.Any(r => r.Selected));
        SelectAllProvisionCommand = new RelayCommand(() => SetAllProvisionRows(true), () => !IsBusy && ProvisionRows.Count > 0);
        DeselectAllProvisionCommand = new RelayCommand(() => SetAllProvisionRows(false), () => !IsBusy && ProvisionRows.Count > 0);
        LoadBlanketFromProvisionCommand = new RelayCommand(LoadBlanketFromProvision, () => !IsBusy && ProvisionRows.Any(r => string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase)));
        AddBlanketDevicesCommand = new AsyncRelayCommand(_ => AddBlanketDevicesAsync(), () => !IsBusy && !string.IsNullOrWhiteSpace(BlanketDeviceInput));
        ScanAndLoadBlanketCommand = new AsyncRelayCommand(_ => ScanAndLoadBlanketAsync(), CanStartScan);
        LoadBlanketFromScanCommand = new AsyncRelayCommand(_ => LoadBlanketFromScanAsync(), () => !IsBusy && ScanResults.Count > 0);
        ClearBlanketDevicesCommand = new RelayCommand(ClearBlanketDevices, () => !IsBusy && BlanketRows.Count > 0);
        FetchBlanketCapabilitiesCommand = new AsyncRelayCommand(_ => FetchBlanketCapabilitiesAsync(), () => !IsBusy && BlanketRows.Count > 0);
        ApplyBlanketSettingsCommand = new AsyncRelayCommand(_ => ApplyBlanketSettingsAsync(promptForReboot: true), CanApplyBlanketSettings);
        RebootSelectedBlanketCommand = new AsyncRelayCommand(_ => RebootSelectedBlanketAsync(), () => !IsBusy && !IsWorkflowRebootWaiting && BlanketRows.Any(r => r.Selected));
        SelectAllBlanketCommand = new RelayCommand(() => SetAllBlanketRows(true), () => !IsBusy && BlanketRows.Count > 0);
        DeselectAllBlanketCommand = new RelayCommand(() => SetAllBlanketRows(false), () => !IsBusy && BlanketRows.Count > 0);
        AddPerDeviceDevicesCommand = new AsyncRelayCommand(_ => AddPerDeviceDevicesAsync(), () => !IsBusy && !string.IsNullOrWhiteSpace(PerDeviceInput));
        ScanAndLoadPerDeviceCommand = new AsyncRelayCommand(_ => ScanAndLoadPerDeviceAsync(), CanStartScan);
        LoadPerDeviceFromBlanketCommand = new AsyncRelayCommand(_ => LoadPerDeviceFromBlanketAsync(), () => !IsBusy && BlanketRows.Count > 0);
        LoadPerDeviceFromProvisionCommand = new AsyncRelayCommand(_ => LoadPerDeviceFromProvisionAsync(), () => !IsBusy && ProvisionRows.Any(r => string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase)));
        FetchPerDeviceStateCommand = new AsyncRelayCommand(_ => FetchPerDeviceStateAsync(), () => !IsBusy && PerDeviceRows.Count > 0);
        ApplyPerDeviceChangesCommand = new AsyncRelayCommand(_ => ApplyPerDeviceChangesAsync(promptForReboot: true), CanApplyPerDeviceChanges);
        RebootSelectedPerDeviceCommand = new AsyncRelayCommand(_ => RebootSelectedPerDeviceAsync(), () => !IsBusy && !IsWorkflowRebootWaiting && PerDeviceRows.Any(r => r.Selected));
        SelectAllPerDeviceCommand = new RelayCommand(() => SetAllPerDeviceRows(true), () => !IsBusy && PerDeviceRows.Count > 0);
        DeselectAllPerDeviceCommand = new RelayCommand(() => SetAllPerDeviceRows(false), () => !IsBusy && PerDeviceRows.Count > 0);
        ClearPerDeviceCommand = new RelayCommand(ClearPerDeviceRows, () => !IsBusy && PerDeviceRows.Count > 0);
        SaveSettingsCommand = new AsyncRelayCommand(_ => SaveSettingsAsync(), () => !IsBusy);
        ClearSettingsPasswordCommand = new RelayCommand(ClearSettingsPassword, () => !IsBusy && SettingsHasSavedPassword);
        ReloadSettingsCommand = new RelayCommand(LoadSettingsForEditor, () => !IsBusy);
        OpenSettingsFolderCommand = new RelayCommand(OpenSettingsFolder, () => !string.IsNullOrWhiteSpace(SettingsDirectory));
        OpenOutputFolderCommand = new RelayCommand(OpenOutputFolder, () => !string.IsNullOrWhiteSpace(DataRoot));

        Subnets.CollectionChanged += OnSubnetsChanged;
        ScanResults.CollectionChanged += OnScanResultsChanged;
        ProvisionRows.CollectionChanged += OnProvisionRowsChanged;
        BlanketRows.CollectionChanged += OnBlanketRowsChanged;
        PerDeviceRows.CollectionChanged += OnPerDeviceRowsChanged;
        PerDeviceAvRows.CollectionChanged += OnPerDeviceAvRowsChanged;
        PerDeviceMulticastRows.CollectionChanged += OnPerDeviceAvRowsChanged;
        PerDeviceControlSubnetRows.CollectionChanged += OnPerDeviceAvRowsChanged;
        LoadSettingsForEditor();
        LoadSubnets();
        InitializeWorkflowSteps();
    }

    public ObservableCollection<WorkflowStepRow> WorkflowSteps { get; } = new();
    public ObservableCollection<SubnetOption> Subnets { get; } = new();
    public ObservableCollection<ScanDeviceRow> ScanResults { get; } = new();
    public ObservableCollection<ProvisionDeviceRow> ProvisionRows { get; } = new();
    public ObservableCollection<BlanketDeviceRow> BlanketRows { get; } = new();
    public ObservableCollection<PerDeviceDeviceRow> PerDeviceRows { get; } = new();
    public ObservableCollection<PerDeviceAvRow> PerDeviceAvRows { get; } = new();
    public ObservableCollection<PerDeviceMulticastRow> PerDeviceMulticastRows { get; } = new();
    public ObservableCollection<PerDeviceControlSubnetRow> PerDeviceControlSubnetRows { get; } = new();
    public ObservableCollection<string> GlobalEdidNameOptions { get; } = new();

    public AsyncRelayCommand StartWorkflowCommand { get; }
    public AsyncRelayCommand ContinueWorkflowCommand { get; }
    public RelayCommand CancelWorkflowCommand { get; }
    public RelayCommand SkipWorkflowRebootWaitCommand { get; }
    public AsyncRelayCommand StartScanCommand { get; }
    public RelayCommand CancelScanCommand { get; }
    public RelayCommand AddSubnetCommand { get; }
    public RelayCommand SelectAllSubnetsCommand { get; }
    public RelayCommand DeselectAllSubnetsCommand { get; }
    public RelayCommand LoadProvisionFromScanCommand { get; }
    public AsyncRelayCommand ProvisionSelectedCommand { get; }
    public AsyncRelayCommand RebootSelectedProvisionCommand { get; }
    public RelayCommand SelectAllProvisionCommand { get; }
    public RelayCommand DeselectAllProvisionCommand { get; }
    public RelayCommand LoadBlanketFromProvisionCommand { get; }
    public AsyncRelayCommand AddBlanketDevicesCommand { get; }
    public AsyncRelayCommand ScanAndLoadBlanketCommand { get; }
    public AsyncRelayCommand LoadBlanketFromScanCommand { get; }
    public RelayCommand ClearBlanketDevicesCommand { get; }
    public AsyncRelayCommand FetchBlanketCapabilitiesCommand { get; }
    public AsyncRelayCommand ApplyBlanketSettingsCommand { get; }
    public AsyncRelayCommand RebootSelectedBlanketCommand { get; }
    public RelayCommand SelectAllBlanketCommand { get; }
    public RelayCommand DeselectAllBlanketCommand { get; }
    public AsyncRelayCommand AddPerDeviceDevicesCommand { get; }
    public AsyncRelayCommand ScanAndLoadPerDeviceCommand { get; }
    public AsyncRelayCommand LoadPerDeviceFromBlanketCommand { get; }
    public AsyncRelayCommand LoadPerDeviceFromProvisionCommand { get; }
    public AsyncRelayCommand FetchPerDeviceStateCommand { get; }
    public AsyncRelayCommand ApplyPerDeviceChangesCommand { get; }
    public AsyncRelayCommand RebootSelectedPerDeviceCommand { get; }
    public RelayCommand SelectAllPerDeviceCommand { get; }
    public RelayCommand DeselectAllPerDeviceCommand { get; }
    public RelayCommand ClearPerDeviceCommand { get; }
    public AsyncRelayCommand SaveSettingsCommand { get; }
    public RelayCommand ClearSettingsPasswordCommand { get; }
    public RelayCommand ReloadSettingsCommand { get; }
    public RelayCommand OpenSettingsFolderCommand { get; }
    public RelayCommand OpenOutputFolderCommand { get; }

    public string RepoRoot => _backend.RepoRoot;

    public string AppVersion => GetAppVersionText();

    public string SettingsPath => _backend.SettingsPath;

    public string SettingsDirectory => Path.GetDirectoryName(SettingsPath) ?? SettingsPath;

    public string DataRoot => _backend.DataRoot;

    public string NewSubnet
    {
        get => _newSubnet;
        set
        {
            if (SetProperty(ref _newSubnet, value))
            {
                AddSubnetCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string BlanketDeviceInput
    {
        get => _blanketDeviceInput;
        set
        {
            if (SetProperty(ref _blanketDeviceInput, value))
            {
                RaiseCommandStates();
            }
        }
    }

    public string PerDeviceInput
    {
        get => _perDeviceInput;
        set
        {
            if (SetProperty(ref _perDeviceInput, value))
            {
                RaiseCommandStates();
            }
        }
    }

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public string WorkflowStatus
    {
        get => _workflowStatus;
        private set => SetProperty(ref _workflowStatus, value);
    }

    public string WorkflowContinueText
    {
        get => _workflowContinueText;
        private set => SetProperty(ref _workflowContinueText, value);
    }

    public string WorkflowRebootCountdown
    {
        get => _workflowRebootCountdown;
        private set => SetProperty(ref _workflowRebootCountdown, value);
    }

    public string SettingsDefaultUsername
    {
        get => _settingsDefaultUsername;
        set
        {
            if (SetProperty(ref _settingsDefaultUsername, value))
            {
                OnPropertyChanged(nameof(CredentialsStatus));
                SaveSettingsCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SettingsDefaultPassword
    {
        get => _settingsDefaultPassword;
        set
        {
            if (SetProperty(ref _settingsDefaultPassword, value))
            {
                SaveSettingsCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SettingsConfirmPassword
    {
        get => _settingsConfirmPassword;
        set => SetProperty(ref _settingsConfirmPassword, value);
    }

    public string SettingsMostUsedSubnets
    {
        get => _settingsMostUsedSubnets;
        set
        {
            if (SetProperty(ref _settingsMostUsedSubnets, value))
            {
                SaveSettingsCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool SettingsDarkMode
    {
        get => _settingsDarkMode;
        set
        {
            if (SetProperty(ref _settingsDarkMode, value))
            {
                SaveSettingsCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool SettingsHasSavedPassword
    {
        get => _settingsHasSavedPassword;
        private set
        {
            if (SetProperty(ref _settingsHasSavedPassword, value))
            {
                OnPropertyChanged(nameof(SettingsSavedPasswordStatus));
                OnPropertyChanged(nameof(CredentialsStatus));
                ClearSettingsPasswordCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string SettingsSavedPasswordStatus => SettingsHasSavedPassword
        ? "Saved password: yes. Leave password blank to keep it."
        : "Saved password: no.";

    public string CredentialsStatus =>
        SettingsHasSavedPassword && !string.IsNullOrWhiteSpace(SettingsDefaultUsername)
            ? $"Credentials: {SettingsDefaultUsername}"
            : "Credentials: not saved";

    public string SettingsStatus
    {
        get => _settingsStatus;
        private set => SetProperty(ref _settingsStatus, value);
    }

    public int MainTabIndex
    {
        get => _mainTabIndex;
        set => SetProperty(ref _mainTabIndex, value);
    }

    public bool IsWorkflowRunning
    {
        get => _isWorkflowRunning;
        private set
        {
            if (SetProperty(ref _isWorkflowRunning, value))
            {
                RaiseCommandStates();
            }
        }
    }

    public bool IsWorkflowWaiting
    {
        get => _isWorkflowWaiting;
        private set
        {
            if (SetProperty(ref _isWorkflowWaiting, value))
            {
                OnPropertyChanged(nameof(IsWorkflowWaitingOnBlanket));
                OnPropertyChanged(nameof(IsWorkflowWaitingOnPerDevice));
                RaiseCommandStates();
            }
        }
    }

    public bool IsWorkflowWaitingOnBlanket => IsWorkflowWaiting && _workflowWaitStage == WorkflowWaitStage.Blanket;

    public bool IsWorkflowWaitingOnPerDevice => IsWorkflowWaiting && _workflowWaitStage == WorkflowWaitStage.PerDevice;

    public bool IsWorkflowRebootWaiting
    {
        get => _isWorkflowRebootWaiting;
        private set
        {
            if (SetProperty(ref _isWorkflowRebootWaiting, value))
            {
                SkipWorkflowRebootWaitCommand.RaiseCanExecuteChanged();
                RaiseCommandStates();
            }
        }
    }

    public string ProgressText
    {
        get => _progressText;
        private set => SetProperty(ref _progressText, value);
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (!SetProperty(ref _isBusy, value))
            {
                return;
            }

            OnPropertyChanged(nameof(IsIdle));
            RaiseCommandStates();
        }
    }

    public bool IsIdle => !IsBusy;

    public IReadOnlyList<TimeZoneOption> TimeZoneOptions { get; } =
    [
        new("004", "Hawaii Standard Time (UTC-10:00)"),
        new("005", "Alaska Standard Time (UTC-09:00)"),
        new("008", "Pacific Time (US & Canada) (UTC-08:00)"),
        new("009", "Mountain Time (US & Canada) (UTC-07:00)"),
        new("010", "Central Time (US & Canada) (UTC-06:00)"),
        new("014", "Eastern Time (US & Canada) (UTC-05:00)"),
        new("015", "Atlantic Time (Canada) (UTC-04:00)"),
        new("017", "Newfoundland (UTC-03:30)"),
        new("023", "UTC / Coordinated Universal Time")
    ];

    public IReadOnlyList<string> InputHdcpOptions { get; } =
    [
        "Auto",
        "HDCP 1.4",
        "HDCP 2.x",
        "Never Authenticate"
    ];

    public IReadOnlyList<string> OutputHdcpOptions { get; } =
    [
        "Auto",
        "FollowInput",
        "ForceHighest",
        "NeverAuthenticate"
    ];

    public IReadOnlyList<string> OutputResolutionOptions { get; } =
    [
        "Auto",
        "3840x2160@60",
        "3840x2160@30",
        "1920x1080@60",
        "1920x1080@30",
        "1280x720@60"
    ];

    public IReadOnlyList<string> IgmpVersionOptions { get; } =
    [
        "N/A",
        "V2",
        "V3"
    ];

    public IReadOnlyList<string> GlobalEdidTypeOptions { get; } =
    [
        "Copy",
        "System",
        "Custom"
    ];

    public IReadOnlyList<string> IpModeOptions { get; } =
    [
        "N/A",
        "DHCP",
        "Static"
    ];

    public IReadOnlyList<string> ToggleOptions { get; } =
    [
        "N/A",
        "Enabled",
        "Disabled"
    ];

    public bool ApplyNtp
    {
        get => _applyNtp;
        set => SetBlanketOption(ref _applyNtp, value);
    }

    public string NtpServer
    {
        get => _ntpServer;
        set => SetProperty(ref _ntpServer, value);
    }

    public string TimeZoneCode
    {
        get => _timeZoneCode;
        set => SetProperty(ref _timeZoneCode, value);
    }

    public bool ApplyCloud
    {
        get => _applyCloud;
        set => SetBlanketOption(ref _applyCloud, value);
    }

    public bool CloudEnabled
    {
        get => _cloudEnabled;
        set => SetProperty(ref _cloudEnabled, value);
    }

    public bool ApplyFusion
    {
        get => _applyFusion;
        set => SetBlanketOption(ref _applyFusion, value);
    }

    public bool FusionEnabled
    {
        get => _fusionEnabled;
        set => SetProperty(ref _fusionEnabled, value);
    }

    public bool ApplyAutoUpdate
    {
        get => _applyAutoUpdate;
        set => SetBlanketOption(ref _applyAutoUpdate, value);
    }

    public bool AutoUpdateEnabled
    {
        get => _autoUpdateEnabled;
        set => SetProperty(ref _autoUpdateEnabled, value);
    }

    public bool ApplyDisplay
    {
        get => _applyDisplay;
        set => SetBlanketOption(ref _applyDisplay, value);
    }

    public bool AutoBrightnessEnabled
    {
        get => _autoBrightnessEnabled;
        set => SetProperty(ref _autoBrightnessEnabled, value);
    }

    public int Brightness
    {
        get => _brightness;
        set => SetProperty(ref _brightness, value);
    }

    public bool ScreensaverEnabled
    {
        get => _screensaverEnabled;
        set => SetProperty(ref _screensaverEnabled, value);
    }

    public int StandbyTimeout
    {
        get => _standbyTimeout;
        set => SetProperty(ref _standbyTimeout, value);
    }

    public bool ToolbarEnabled
    {
        get => _toolbarEnabled;
        set => SetProperty(ref _toolbarEnabled, value);
    }

    public bool ApplyAvFramework
    {
        get => _applyAvFramework;
        set => SetBlanketOption(ref _applyAvFramework, value);
    }

    public bool AvFrameworkEnabled
    {
        get => _avFrameworkEnabled;
        set => SetProperty(ref _avFrameworkEnabled, value);
    }

    public bool ApplyInputHdcp
    {
        get => _applyInputHdcp;
        set => SetBlanketOption(ref _applyInputHdcp, value);
    }

    public string InputHdcpMode
    {
        get => _inputHdcpMode;
        set => SetProperty(ref _inputHdcpMode, value);
    }

    public bool ApplyOutputHdcp
    {
        get => _applyOutputHdcp;
        set => SetBlanketOption(ref _applyOutputHdcp, value);
    }

    public string OutputHdcpMode
    {
        get => _outputHdcpMode;
        set => SetProperty(ref _outputHdcpMode, value);
    }

    public bool ApplyOutputResolution
    {
        get => _applyOutputResolution;
        set => SetBlanketOption(ref _applyOutputResolution, value);
    }

    public string OutputResolution
    {
        get => _outputResolution;
        set => SetProperty(ref _outputResolution, value);
    }

    public bool ApplyGlobalEdid
    {
        get => _applyGlobalEdid;
        set => SetBlanketOption(ref _applyGlobalEdid, value);
    }

    public string GlobalEdidName
    {
        get => _globalEdidName;
        set => SetProperty(ref _globalEdidName, value);
    }

    public string GlobalEdidType
    {
        get => _globalEdidType;
        set => SetProperty(ref _globalEdidType, value);
    }

    public string SelectedSubnetSummary
    {
        get
        {
            var selected = Subnets.Count(s => s.IsSelected);
            return $"{selected} of {Subnets.Count} subnet(s) selected";
        }
    }

    public string ScanSummary
    {
        get
        {
            var selected = ScanResults.Count(r => r.Selected);
            return $"Found {ScanResults.Count} device(s). Selected: {selected}.";
        }
    }

    public string ProvisionSummary
    {
        get
        {
            var selected = ProvisionRows.Count(r => r.Selected);
            var success = ProvisionRows.Count(r => string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase));
            var failed = ProvisionRows.Count(r =>
                !string.IsNullOrWhiteSpace(r.Status) &&
                !string.Equals(r.Status, "Pending", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "Working", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase));

            return $"Loaded {ProvisionRows.Count} device(s). Selected: {selected}. Success: {success}. Failed: {failed}.";
        }
    }

    public string BlanketSummary
    {
        get
        {
            var selected = BlanketRows.Count(r => r.Selected);
            var ok = BlanketRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase) || string.Equals(r.Status, "Rebooting", StringComparison.OrdinalIgnoreCase));
            var failed = BlanketRows.Count(r =>
                !string.IsNullOrWhiteSpace(r.Status) &&
                !string.Equals(r.Status, "Pending", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "Working", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "Rebooting", StringComparison.OrdinalIgnoreCase));
            var reboot = BlanketRows.Count(r => r.NeedsReboot);

            return $"Loaded {BlanketRows.Count} device(s). Selected: {selected}. OK: {ok}. Failed: {failed}. Reboot needed: {reboot}.";
        }
    }

    public string PerDeviceSummary
    {
        get
        {
            var selected = PerDeviceRows.Count(r => r.Selected);
            var selectedIps = PerDeviceRows.Where(r => r.Selected).Select(r => r.IP).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var edited = PerDeviceRows.Count(r => r.HasChanges) +
                         PerDeviceAvRows.Count(r => selectedIps.Contains(r.IP) && r.HasChanges) +
                         PerDeviceMulticastRows.Count(r => selectedIps.Contains(r.IP) && r.HasChanges) +
                         PerDeviceControlSubnetRows.Count(r => selectedIps.Contains(r.IP) && r.HasChanges);
            var ok = PerDeviceRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase) || string.Equals(r.Status, "Rebooting", StringComparison.OrdinalIgnoreCase));
            var failed = PerDeviceRows.Count(r =>
                !string.IsNullOrWhiteSpace(r.Status) &&
                !string.Equals(r.Status, "Pending", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "Working", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(r.Status, "Rebooting", StringComparison.OrdinalIgnoreCase));
            var reboot = PerDeviceRows.Count(r => r.NeedsReboot);

            return $"Loaded {PerDeviceRows.Count} device(s). Selected: {selected}. With changes: {edited}. OK: {ok}. Failed: {failed}. Reboot needed: {reboot}.";
        }
    }

    private async Task StartWorkflowAsync()
    {
        var selectedCidrs = PromptForScanSubnets(
            "Full Workflow Scan Subnets",
            "Choose the subnet(s) to scan for first-boot devices before starting the workflow.");
        if (selectedCidrs is null)
        {
            WorkflowStatus = "Workflow cancelled before scan.";
            return;
        }

        ResetWorkflow();
        _workflowCancelRequested = false;
        SetWorkflowRunning(true, false);
        MainTabIndex = 0;
        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
                WorkflowStatus = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            WorkflowStatus = "Workflow running...";

            SetWorkflowStep(0, "Running", $"Scanning {selectedCidrs.Length} subnet(s) for first-boot devices...");
            ScanResults.Clear();
            var scanRows = await _backend.ScanBootupAsync(selectedCidrs, progress, _scanCancellation.Token).ConfigureAwait(true);
            foreach (var row in scanRows)
            {
                ScanResults.Add(row);
            }

            LoadProvisionFromScan();
            SetWorkflowStep(0, "Done", $"Found {ScanResults.Count} first-boot device(s).");
            if (ScanResults.Count == 0)
            {
                SetWorkflowStep(1, "Skipped", "No devices to provision.");
                WorkflowStatus = "Workflow stopped: no devices found.";
                SetWorkflowRunning(false, false);
                return;
            }

            var provisionTargets = ProvisionRows.Where(r => r.Selected).ToArray();
            IsBusy = false;
            var provisionCredential = await PromptForProvisionCredentialsAsync(provisionTargets.Length).ConfigureAwait(true);
            if (provisionCredential is null)
            {
                SetWorkflowStep(1, "Cancelled", "Provisioning credentials were not entered.");
                WorkflowStatus = "Workflow stopped: provisioning credentials were cancelled.";
                SetWorkflowRunning(false, false);
                return;
            }

            IsBusy = true;
            SetWorkflowStep(1, "Running", $"Provisioning {provisionTargets.Length} device(s)...");
            foreach (var row in provisionTargets)
            {
                row.Status = "Working";
                row.Success = "";
                row.Response = "";
                row.Timestamp = "";
            }

            var provisionResults = await _backend
                .ProvisionAdminAsync(provisionTargets.Select(r => r.IP), provisionCredential.Username, provisionCredential.Password, progress, _scanCancellation.Token)
                .ConfigureAwait(true);

            var byIp = provisionResults.ToDictionary(r => r.IP, StringComparer.OrdinalIgnoreCase);
            foreach (var row in provisionTargets)
            {
                if (!byIp.TryGetValue(row.IP, out var result))
                {
                    row.Status = "No result";
                    row.Success = "False";
                    continue;
                }

                row.Status = NormalizeProvisionStatus(result.Status, result.Success);
                row.Success = result.Success;
                row.Response = result.Response;
                row.Timestamp = result.Timestamp;
            }

            _sessionUsername = provisionCredential.Username;
            _sessionPassword = provisionCredential.Password;

            var provisionOk = provisionTargets.Count(r => string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase));
            SetWorkflowStep(1, provisionOk > 0 ? "Done" : "Failed", $"Provisioned {provisionOk} of {provisionTargets.Length} device(s).");
            LoadBlanketFromProvision();

            SetWorkflowStep(2, "Running", $"Scanning {selectedCidrs.Length} subnet(s) for additional reachable devices...");
            var reachableScanRows = await _backend.ScanReachableDevicesAsync(selectedCidrs, progress, _scanCancellation.Token).ConfigureAwait(true);
            var additionalRows = AddOrSelectBlanketDevices(reachableScanRows.Select(r => r.IP));
            foreach (var target in additionalRows)
            {
                var scanRow = reachableScanRows.FirstOrDefault(r => string.Equals(r.IP, target.IP, StringComparison.OrdinalIgnoreCase));
                if (scanRow is not null && string.Equals(target.Status, "Pending", StringComparison.OrdinalIgnoreCase))
                {
                    target.Detail = $"Discovered: {scanRow.MatchedSig}";
                    target.Timestamp = scanRow.ScannedAt;
                }
            }

            if (BlanketRows.Count == 0)
            {
                WorkflowStatus = "Workflow stopped: no devices found to configure.";
                SetWorkflowRunning(false, false);
                return;
            }

            SetWorkflowStep(2, "Running", $"Fetching blanket capabilities for {BlanketRows.Count} device(s)...");
            var blanketResults = await _backend
                .FetchBlanketCapabilitiesAsync(BlanketRows.Select(r => r.IP), _sessionUsername, _sessionPassword, progress, _scanCancellation.Token)
                .ConfigureAwait(true);
            ApplyBlanketResults(blanketResults);
            var blanketOk = BlanketRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase));
            SetWorkflowStep(2, "Waiting", $"Fetched capabilities for {blanketOk} device(s). Apply shared settings on the Blanket Settings tab, then continue.");
            WorkflowStatus = "Waiting for Blanket Settings review.";
            WorkflowContinueText = "Continue to Per Device";
            SetWorkflowWaitStage(WorkflowWaitStage.Blanket);
            MainTabIndex = 3;
            SetWorkflowRunning(true, true);
        }
        catch (OperationCanceledException)
        {
            WorkflowStatus = "Workflow cancelled.";
            if (WorkflowSteps.Any(s => s.State == "Running"))
            {
                SetWorkflowStep(WorkflowSteps.ToList().FindIndex(s => s.State == "Running"), "Cancelled", "Cancelled by user.");
            }
            SetWorkflowRunning(false, false);
        }
        catch (Exception ex)
        {
            WorkflowStatus = $"Workflow stopped: {ex.Message}";
            var runningIndex = WorkflowSteps.ToList().FindIndex(s => s.State == "Running");
            if (runningIndex >= 0)
            {
                SetWorkflowStep(runningIndex, "Failed", ex.Message);
            }
            SetWorkflowRunning(false, false);
            MessageBox.Show(ex.Message, "Workflow failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(ScanSummary));
            OnPropertyChanged(nameof(ProvisionSummary));
            OnPropertyChanged(nameof(BlanketSummary));
        }
    }

    private async Task ContinueWorkflowAsync()
    {
        if (!IsWorkflowRunning || !IsWorkflowWaiting)
        {
            return;
        }

        if (_workflowWaitStage == WorkflowWaitStage.Blanket)
        {
            await ContinueWorkflowToPerDeviceAsync().ConfigureAwait(true);
            return;
        }

        if (_workflowWaitStage == WorkflowWaitStage.PerDevice)
        {
            await FinishWorkflowPerDeviceAsync().ConfigureAwait(true);
        }
    }

    private async Task ContinueWorkflowToPerDeviceAsync()
    {
        SetWorkflowRunning(true, false);
        SetWorkflowWaitStage(WorkflowWaitStage.None);
        SetWorkflowStep(2, "Done", "Blanket Settings review complete.");
        SetWorkflowStep(3, "Running", "Loading Per Device and fetching current state...");
        MainTabIndex = 4;

        try
        {
            var targets = AddOrSelectPerDeviceRows(BlanketRows.Select(r => r.IP));
            await FetchPerDeviceStateForRowsAsync(targets).ConfigureAwait(true);
            var ok = PerDeviceRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase));
            SetWorkflowStep(3, "Waiting", $"Fetched current state for {ok} device(s). Edit Per Device values, then continue.");
            WorkflowStatus = "Waiting for Per Device edits.";
            WorkflowContinueText = "Apply Per Device";
            SetWorkflowWaitStage(WorkflowWaitStage.PerDevice);
            SetWorkflowRunning(true, true);
        }
        catch (Exception ex)
        {
            SetWorkflowStep(3, "Failed", ex.Message);
            WorkflowStatus = $"Workflow stopped: {ex.Message}";
            SetWorkflowRunning(false, false);
            MessageBox.Show(ex.Message, "Workflow failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async Task FinishWorkflowPerDeviceAsync()
    {
        SetWorkflowRunning(true, false);
        SetWorkflowWaitStage(WorkflowWaitStage.None);
        SetWorkflowStep(3, "Running", "Applying Per Device changes...");

        try
        {
            if (CanApplyPerDeviceChanges())
            {
                await ApplyPerDeviceChangesAsync(promptForReboot: false, skipConfirm: true).ConfigureAwait(true);
                var ok = PerDeviceRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase));
                SetWorkflowStep(3, "Done", $"Applied Per Device changes. {ok} device(s) OK.");
            }
            else
            {
                SetWorkflowStep(3, "Skipped", "No Per Device changes to apply.");
            }
        }
        catch (Exception ex)
        {
            SetWorkflowStep(3, "Failed", ex.Message);
            WorkflowStatus = $"Workflow stopped: {ex.Message}";
            SetWorkflowRunning(false, false);
            MessageBox.Show(Application.Current.MainWindow, ex.Message, "Workflow failed", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        await RunWorkflowRebootStepAsync().ConfigureAwait(true);
    }

    private async Task RunWorkflowRebootStepAsync()
    {
        MainTabIndex = 0;
        SetWorkflowStep(4, "Running", "Preparing reboot list...");

        var perDeviceRebootRows = PerDeviceRows
            .Where(r => r.Selected && r.NeedsReboot)
            .ToArray();
        var perDeviceOriginalIps = perDeviceRebootRows
            .Select(r => r.IP)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var rebootIps = perDeviceRebootRows
            .Select(GetEffectiveFetchIp)
            .Concat(BlanketRows
                .Where(r => r.Selected && r.NeedsReboot && !perDeviceOriginalIps.Contains(r.IP))
                .Select(r => r.IP))
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (rebootIps.Length == 0)
        {
            SetWorkflowStep(4, "Skipped", "No devices were marked as needing reboot.");
            WorkflowStatus = "Workflow complete. No reboot needed.";
            WorkflowContinueText = "Continue Workflow";
            SetWorkflowRunning(false, false);
            MessageBox.Show(
                Application.Current.MainWindow,
                "Workflow complete!\n\nNo devices required a reboot.",
                "Workflow Complete",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        var rebootConfirm = MessageBox.Show(
            $"{rebootIps.Length} device(s) are marked as needing a reboot. Send reboot commands now?",
            "Reboot Needed",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (rebootConfirm != MessageBoxResult.Yes)
        {
            SetWorkflowStep(4, "Skipped", $"Reboot deferred for {rebootIps.Length} device(s).");
            WorkflowStatus = "Workflow complete. Reboot deferred.";
            WorkflowContinueText = "Continue Workflow";
            SetWorkflowRunning(false, false);
            MessageBox.Show(
                Application.Current.MainWindow,
                $"Workflow complete!\n\nReboot was deferred for {rebootIps.Length} device(s).\nRemember to reboot them manually when ready.",
                "Workflow Complete",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
                WorkflowStatus = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            WorkflowStatus = $"Sending reboot commands to {rebootIps.Length} device(s)...";
            SetWorkflowStep(4, "Running", $"Sending reboot commands to {rebootIps.Length} device(s)...");

            var results = await _backend.RebootDevicesAsync(rebootIps, _sessionUsername, _sessionPassword, progress, _scanCancellation.Token).ConfigureAwait(true);
            var byIp = results.ToDictionary(r => r.IP, StringComparer.OrdinalIgnoreCase);

            foreach (var row in perDeviceRebootRows)
            {
                if (byIp.TryGetValue(GetEffectiveFetchIp(row), out var result) ||
                    byIp.TryGetValue(row.IP, out result))
                {
                    row.Status = result.Success ? "Rebooting" : "Reboot failed";
                    row.Detail = result.Success ? "Reboot command accepted." : result.Response;
                    row.Timestamp = result.Timestamp;
                }
            }

            var accepted = results.Count(r => r.Success);
            var errors = rebootIps.Length - accepted;
            if (accepted == 0)
            {
                SetWorkflowStep(4, "Failed", $"No reboot commands were accepted. Errors: {errors}.");
                WorkflowStatus = "Workflow stopped: no reboot commands were accepted.";
                WorkflowContinueText = "Continue Workflow";
                SetWorkflowRunning(false, false);
                MessageBox.Show(
                    Application.Current.MainWindow,
                    $"Reboot commands failed for all {rebootIps.Length} device(s).\n\nCheck that credentials are saved in Settings and that devices are reachable.",
                    "Reboot Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                return;
            }

            SetWorkflowStep(4, "Waiting", $"Reboot command accepted for {accepted} device(s). Waiting {WorkflowRebootWait.TotalMinutes:0} minutes...");
            WorkflowStatus = $"Rebooting {accepted} device(s). Waiting for devices to come back online...";
            IsBusy = false;

            var skipped = await WaitForWorkflowRebootAsync(accepted, errors).ConfigureAwait(true);
            if (_workflowCancelRequested)
            {
                SetWorkflowStep(4, "Cancelled", "Cancelled during reboot wait.");
                WorkflowStatus = "Workflow cancelled during reboot wait.";
                SetWorkflowRunning(false, false);
                return;
            }

            // Auto-fetch state for rebooted devices after wait completes.
            // Rows whose IP was changed to a new static address are re-keyed first
            // so the fetch targets the address the device actually booted on.
            var (blanketTargets, perDeviceTargets) = PromoteNewIpsAfterReboot(rebootIps);

            if (blanketTargets.Count > 0)
            {
                await FetchBlanketCapabilitiesForRowsAsync(blanketTargets).ConfigureAwait(true);
            }

            if (perDeviceTargets.Count > 0)
            {
                await FetchPerDeviceStateForRowsAsync(perDeviceTargets).ConfigureAwait(true);
            }

            SetWorkflowStep(
                4,
                "Done",
                skipped
                    ? $"Reboot wait skipped. Reboot commands accepted: {accepted}. Errors: {errors}."
                    : $"Reboot wait complete. Reboot commands accepted: {accepted}. Errors: {errors}.");
            WorkflowStatus = "Workflow complete.";
            WorkflowContinueText = "Continue Workflow";
            SetWorkflowRunning(false, false);

            var completionMsg = skipped
                ? $"Workflow complete!\n\n{accepted} device(s) were rebooted (wait skipped).\nDevice state has been refreshed."
                : $"Workflow complete!\n\n{accepted} device(s) rebooted and are back online.\nDevice state has been refreshed.";
            if (errors > 0)
                completionMsg += $"\n\n⚠  {errors} device(s) failed to accept the reboot command.";
            MessageBox.Show(Application.Current.MainWindow, completionMsg, "Workflow Complete", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (OperationCanceledException)
        {
            SetWorkflowStep(4, "Cancelled", "Cancelled by user.");
            WorkflowStatus = "Workflow cancelled.";
            SetWorkflowRunning(false, false);
        }
        catch (Exception ex)
        {
            SetWorkflowStep(4, "Failed", ex.Message);
            WorkflowStatus = $"Workflow stopped: {ex.Message}";
            SetWorkflowRunning(false, false);
            MessageBox.Show(Application.Current.MainWindow, ex.Message, "Reboot failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            WorkflowRebootCountdown = "";
            IsWorkflowRebootWaiting = false;
            OnPropertyChanged(nameof(PerDeviceSummary));
        }
    }

    private async Task<bool> WaitForWorkflowRebootAsync(int accepted, int errors)
    {
        _workflowRebootWaitCancellation?.Dispose();
        _workflowRebootWaitCancellation = new CancellationTokenSource();
        IsWorkflowRebootWaiting = true;

        var skipped = false;
        var endAt = DateTimeOffset.Now.Add(WorkflowRebootWait);

        try
        {
            while (true)
            {
                var remaining = endAt - DateTimeOffset.Now;
                if (remaining <= TimeSpan.Zero)
                {
                    break;
                }

                var detail = $"Waiting {remaining:mm\\:ss} for reboot. Accepted: {accepted}. Errors: {errors}.";
                WorkflowRebootCountdown = $"{detail} You can skip the wait when devices are ready.";
                WorkflowStatus = WorkflowRebootCountdown;
                SetWorkflowStep(4, "Waiting", detail);
                await Task.Delay(TimeSpan.FromSeconds(1), _workflowRebootWaitCancellation.Token).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            if (_workflowCancelRequested)
            {
                throw;
            }

            skipped = true;
            WorkflowRebootCountdown = "Reboot wait skipped.";
            WorkflowStatus = WorkflowRebootCountdown;
        }
        finally
        {
            _workflowRebootWaitCancellation?.Dispose();
            _workflowRebootWaitCancellation = null;
            IsWorkflowRebootWaiting = false;
        }

        return skipped;
    }

    private async Task StartScanAsync()
    {
        var selectedCidrs = PromptForScanSubnets(
            "Scan Subnets",
            "Choose the subnet(s) to scan for first-boot devices.");
        if (selectedCidrs is null)
        {
            StatusText = "Scan cancelled.";
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            ScanResults.Clear();
            OnPropertyChanged(nameof(ScanSummary));
            ProgressText = "Starting scan...";
            StatusText = $"Scanning {selectedCidrs.Length} subnet(s)...";

            var rows = await _backend.ScanBootupAsync(selectedCidrs, progress, _scanCancellation.Token).ConfigureAwait(true);

            foreach (var row in rows)
            {
                ScanResults.Add(row);
            }

            LoadProvisionFromScan();
            ProgressText = "Scan complete.";
            StatusText = $"Scan complete. Found {ScanResults.Count} device(s).";
            OnPropertyChanged(nameof(ScanSummary));
        }
        catch (OperationCanceledException)
        {
            ProgressText = "Scan cancelled.";
            StatusText = "Scan cancelled.";
        }
        catch (Exception ex)
        {
            ProgressText = "Scan failed.";
            StatusText = $"Scan failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Scan failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
        }
    }

    private async Task ProvisionSelectedAsync()
    {
        var selectedRows = ProvisionRows.Where(r => r.Selected).ToArray();
        if (selectedRows.Length == 0)
        {
            MessageBox.Show("Select at least one device to provision.", "Nothing selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var provisionCredential = await PromptForProvisionCredentialsAsync(selectedRows.Length).ConfigureAwait(true);
        if (provisionCredential is null)
        {
            StatusText = "Provision cancelled.";
            return;
        }

        var confirm = MessageBox.Show(
            $"Provision admin credentials for user '{provisionCredential.Username}' on {selectedRows.Length} device(s)?",
            "Confirm Provision",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (confirm != MessageBoxResult.Yes)
        {
            StatusText = "Provision cancelled.";
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            foreach (var row in selectedRows)
            {
                row.Status = "Working";
                row.Success = "";
                row.Response = "";
                row.Timestamp = "";
            }

            OnPropertyChanged(nameof(ProvisionSummary));
            ProgressText = $"Provisioning {selectedRows.Length} device(s)...";
            StatusText = $"Provisioning {selectedRows.Length} device(s)...";

            var results = await _backend
                .ProvisionAdminAsync(selectedRows.Select(r => r.IP), provisionCredential.Username, provisionCredential.Password, progress, _scanCancellation.Token)
                .ConfigureAwait(true);

            var byIp = results.ToDictionary(r => r.IP, StringComparer.OrdinalIgnoreCase);
            foreach (var row in selectedRows)
            {
                if (!byIp.TryGetValue(row.IP, out var result))
                {
                    row.Status = "No result";
                    row.Success = "False";
                    continue;
                }

                row.Status = NormalizeProvisionStatus(result.Status, result.Success);
                row.Success = result.Success;
                row.Response = result.Response;
                row.Timestamp = result.Timestamp;
            }

            _sessionUsername = provisionCredential.Username;
            _sessionPassword = provisionCredential.Password;

            var ok = selectedRows.Count(r => string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase));
            LoadBlanketFromProvision();
            ProgressText = $"Provision complete. {ok} succeeded.";
            StatusText = $"Provision complete. Saved crestron-provisioned.csv.";
            OnPropertyChanged(nameof(ProvisionSummary));
        }
        catch (OperationCanceledException)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Cancelled";
            }

            ProgressText = "Provision cancelled.";
            StatusText = "Provision cancelled.";
        }
        catch (Exception ex)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Error";
                row.Success = "False";
            }

            ProgressText = "Provision failed.";
            StatusText = $"Provision failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Provision failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(ProvisionSummary));
        }
    }

    private async Task FetchBlanketCapabilitiesAsync()
    {
        var selectedRows = BlanketRows.Where(r => r.Selected).ToArray();
        if (selectedRows.Length == 0)
        {
            MessageBox.Show("Select at least one device before fetching capabilities.", "Nothing selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        await FetchBlanketCapabilitiesForRowsAsync(selectedRows).ConfigureAwait(true);
    }

    private async Task FetchBlanketCapabilitiesForRowsAsync(IReadOnlyCollection<BlanketDeviceRow> selectedRows)
    {
        if (selectedRows.Count == 0)
        {
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            foreach (var row in selectedRows)
            {
                row.Status = "Working";
                row.Detail = "";
                row.Timestamp = "";
            }

            ProgressText = $"Fetching capabilities for {selectedRows.Count} device(s)...";
            StatusText = $"Fetching capabilities for {selectedRows.Count} device(s)...";

            var results = await _backend
                .FetchBlanketCapabilitiesAsync(selectedRows.Select(r => r.IP), _sessionUsername, _sessionPassword, progress, _scanCancellation.Token)
                .ConfigureAwait(true);

            ApplyBlanketResults(results);
            ProgressText = "Capability fetch complete.";
            StatusText = "Capability fetch complete.";
        }
        catch (OperationCanceledException)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Cancelled";
            }

            ProgressText = "Capability fetch cancelled.";
            StatusText = "Capability fetch cancelled.";
        }
        catch (Exception ex)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Error";
                row.Detail = ex.Message;
            }

            ProgressText = "Capability fetch failed.";
            StatusText = $"Capability fetch failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Capability fetch failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(BlanketSummary));
        }
    }

    private async Task ApplyBlanketSettingsAsync(bool promptForReboot)
    {
        var selectedRows = BlanketRows.Where(r => r.Selected).ToArray();
        if (selectedRows.Length == 0)
        {
            MessageBox.Show("Select at least one device before applying settings.", "Nothing selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var options = BuildBlanketOptions();
        if (!options.HasAnySelection)
        {
            MessageBox.Show("Enable at least one Blanket Settings section before applying.", "Nothing to apply", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var validation = ValidateBlanketOptions(options);
        if (!string.IsNullOrWhiteSpace(validation))
        {
            MessageBox.Show(validation, "Invalid blanket settings", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var confirm = MessageBox.Show(
            $"Apply selected Blanket Settings to {selectedRows.Length} device(s)?",
            "Confirm Blanket Settings",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirm != MessageBoxResult.Yes)
        {
            StatusText = "Blanket apply cancelled.";
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        var applySucceeded = false;
        try
        {
            IsBusy = true;
            foreach (var row in selectedRows)
            {
                row.Status = "Working";
                row.Detail = "";
                row.NeedsReboot = false;
                row.Timestamp = "";
            }

            ProgressText = $"Applying blanket settings to {selectedRows.Length} device(s)...";
            StatusText = $"Applying blanket settings to {selectedRows.Length} device(s)...";

            var results = await _backend
                .ApplyBlanketSettingsAsync(selectedRows, options, _sessionUsername, _sessionPassword, progress, _scanCancellation.Token)
                .ConfigureAwait(true);

            ApplyBlanketResults(results);
            var ok = selectedRows.Count(r => string.Equals(r.Status, "OK", StringComparison.OrdinalIgnoreCase));
            ProgressText = $"Blanket apply complete. {ok} OK.";
            StatusText = "Blanket apply complete. Saved crestron-settings.csv.";
            applySucceeded = true;

            if (promptForReboot && !IsWorkflowRunning)
            {
                await PromptForRebootNeededAsync(
                    "Blanket Settings",
                    selectedRows.Where(r => r.NeedsReboot).Select(r => r.IP),
                    () => RebootSelectedBlanketAsync(onlyMarkedReboot: true, confirm: false)).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Cancelled";
            }

            ProgressText = "Blanket apply cancelled.";
            StatusText = "Blanket apply cancelled.";
        }
        catch (Exception ex)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Error";
                row.Detail = ex.Message;
            }

            ProgressText = "Blanket apply failed.";
            StatusText = $"Blanket apply failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Blanket apply failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(BlanketSummary));
        }

        // In the Full Workflow, automatically advance to Per Device once blanket settings are applied.
        if (applySucceeded && IsWorkflowRunning && IsWorkflowWaiting && _workflowWaitStage == WorkflowWaitStage.Blanket)
        {
            await ContinueWorkflowToPerDeviceAsync().ConfigureAwait(true);
        }
    }

    private void CancelScan()
    {
        _scanCancellation?.Cancel();
        _workflowRebootWaitCancellation?.Cancel();
        ProgressText = "Cancelling...";
    }

    private void CancelWorkflow()
    {
        _workflowCancelRequested = true;
        _scanCancellation?.Cancel();
        _workflowRebootWaitCancellation?.Cancel();
        SetWorkflowWaitStage(WorkflowWaitStage.None);
        SetWorkflowRunning(false, false);
        WorkflowContinueText = "Continue Workflow";
        WorkflowStatus = "Workflow cancellation requested.";

        var runningIndex = WorkflowSteps.ToList().FindIndex(step => step.State is "Running" or "Waiting");
        if (runningIndex >= 0)
        {
            SetWorkflowStep(runningIndex, "Cancelled", "Cancelled by user.");
        }
    }

    private void InitializeWorkflowSteps()
    {
        WorkflowSteps.Clear();
        WorkflowSteps.Add(new WorkflowStepRow { Number = 1, Name = "Scan", Description = "Find devices on first-boot pages" });
        WorkflowSteps.Add(new WorkflowStepRow { Number = 2, Name = "Provision", Description = "Create the admin account" });
        WorkflowSteps.Add(new WorkflowStepRow { Number = 3, Name = "Blanket Settings", Description = "Fetch capabilities and apply shared settings" });
        WorkflowSteps.Add(new WorkflowStepRow { Number = 4, Name = "Per Device", Description = "Fetch current state and apply per-device edits" });
        WorkflowSteps.Add(new WorkflowStepRow { Number = 5, Name = "Reboot", Description = "Send reboot commands and wait for devices" });
    }

    private void ResetWorkflow()
    {
        InitializeWorkflowSteps();
        SetWorkflowWaitStage(WorkflowWaitStage.None);
        _workflowRebootWaitCancellation?.Cancel();
        IsWorkflowRebootWaiting = false;
        WorkflowRebootCountdown = "";
        WorkflowContinueText = "Continue Workflow";
        WorkflowStatus = "Workflow not running.";
    }

    private void SkipWorkflowRebootWait()
    {
        _workflowRebootWaitCancellation?.Cancel();
    }

    /// <summary>
    /// After a reboot wait completes, promotes any per-device rows that had their IP
    /// changed to a new static address: the old row is replaced in-place with a new
    /// row keyed to the new IP, and the corresponding blanket row is updated the same
    /// way.  Returns the blanket and per-device rows to target for the post-reboot
    /// capability/state fetch (using the new IPs where applicable).
    /// </summary>
    private (List<BlanketDeviceRow> Blanket, List<PerDeviceDeviceRow> PerDevice)
        PromoteNewIpsAfterReboot(IEnumerable<string> rebootedIps)
    {
        var rebootedSet = new HashSet<string>(rebootedIps, StringComparer.OrdinalIgnoreCase);
        var blanketOut  = new List<BlanketDeviceRow>();
        var perDevOut   = new List<PerDeviceDeviceRow>();

        var perDeviceSnapshot = PerDeviceRows
            .Where(r => rebootedSet.Contains(r.IP) || rebootedSet.Contains(GetEffectiveFetchIp(r)))
            .ToList();

        foreach (var oldRow in perDeviceSnapshot)
        {
            var effectiveIp = GetEffectiveFetchIp(oldRow);
            var ipChanged   = !string.Equals(effectiveIp, oldRow.IP, StringComparison.OrdinalIgnoreCase);

            PerDeviceDeviceRow fetchRow;
            if (ipChanged)
            {
                var newRow = new PerDeviceDeviceRow { IP = effectiveIp, Selected = oldRow.Selected, Status = "Pending" };
                ReplacePerDeviceRow(oldRow, newRow);
                // Remove secondary rows keyed to the old IP; the post-reboot fetch will repopulate them under the new IP.
                RemovePerDeviceAvRowsByIp(new HashSet<string>(StringComparer.OrdinalIgnoreCase) { oldRow.IP });
                fetchRow = newRow;
            }
            else
            {
                fetchRow = oldRow;
            }

            perDevOut.Add(fetchRow);

            // Mirror the IP update in BlanketRows
            var blanketOld = BlanketRows.FirstOrDefault(r =>
                string.Equals(r.IP, oldRow.IP, StringComparison.OrdinalIgnoreCase));
            if (blanketOld is not null)
            {
                if (ipChanged)
                {
                    var newBlanket = new BlanketDeviceRow { IP = effectiveIp, Selected = blanketOld.Selected, Status = "Pending" };
                    ReplaceBlanketRow(blanketOld, newBlanket);
                    blanketOut.Add(newBlanket);
                }
                else
                {
                    blanketOut.Add(blanketOld);
                }
            }
        }

        // Also include blanket-only rows (no per-device counterpart) that were rebooted
        var handledIps = perDeviceSnapshot
            .SelectMany(r => new[] { r.IP, GetEffectiveFetchIp(r) })
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var br in BlanketRows.Where(r => rebootedSet.Contains(r.IP) && !handledIps.Contains(r.IP)))
        {
            blanketOut.Add(br);
        }

        return (blanketOut, perDevOut);
    }

    /// <summary>
    /// Returns the IP address the app should connect to AFTER the device reboots.
    /// If the user set a new static IP that is a valid address and differs from the
    /// current IP, that new address is returned; otherwise the original row IP is used.
    /// </summary>
    private static string GetEffectiveFetchIp(PerDeviceDeviceRow row)
    {
        var newIp = row.NewIP?.Trim();
        if (string.IsNullOrWhiteSpace(newIp) ||
            string.Equals(newIp, "N/A", StringComparison.OrdinalIgnoreCase))
            return row.IP;

        if (!System.Net.IPAddress.TryParse(newIp, out _))
            return row.IP;

        if (string.Equals(newIp, row.CurrentIP?.Trim(), StringComparison.OrdinalIgnoreCase))
            return row.IP;

        return newIp;
    }

    private void ReplacePerDeviceRow(PerDeviceDeviceRow oldRow, PerDeviceDeviceRow newRow)
    {
        var idx = PerDeviceRows.IndexOf(oldRow);
        if (idx < 0) return;

        newRow.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PerDeviceSummary));
            RaiseCommandStates();
        };

        PerDeviceRows[idx] = newRow;
    }

    private void ReplaceBlanketRow(BlanketDeviceRow oldRow, BlanketDeviceRow newRow)
    {
        var idx = BlanketRows.IndexOf(oldRow);
        if (idx < 0) return;

        newRow.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(BlanketDeviceRow.Selected)
                or nameof(BlanketDeviceRow.Status)
                or nameof(BlanketDeviceRow.NeedsReboot))
            {
                OnPropertyChanged(nameof(BlanketSummary));
                RaiseCommandStates();
            }
        };

        BlanketRows[idx] = newRow;
    }

    private void SetWorkflowRunning(bool running, bool waiting)
    {
        IsWorkflowRunning = running;
        IsWorkflowWaiting = waiting;
        RaiseCommandStates();
    }

    private void SetWorkflowWaitStage(WorkflowWaitStage stage)
    {
        if (_workflowWaitStage == stage)
        {
            return;
        }

        _workflowWaitStage = stage;
        OnPropertyChanged(nameof(IsWorkflowWaitingOnBlanket));
        OnPropertyChanged(nameof(IsWorkflowWaitingOnPerDevice));
    }

    private void SetWorkflowStep(int index, string state, string detail)
    {
        if (index < 0 || index >= WorkflowSteps.Count)
        {
            return;
        }

        WorkflowSteps[index].State = state;
        WorkflowSteps[index].Detail = detail;
    }

    private void AddSubnet()
    {
        var cidr = NewSubnet.Trim();
        if (!IsValidCidr(cidr))
        {
            MessageBox.Show("Invalid CIDR. Example: 192.168.20.0/24", "Invalid subnet", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (Subnets.Any(s => string.Equals(s.Cidr, cidr, StringComparison.OrdinalIgnoreCase)))
        {
            NewSubnet = "";
            return;
        }

        AddSubnetOption(cidr, true);
        NewSubnet = "";
        StatusText = $"Added subnet {cidr}.";
    }

    private string[]? PromptForScanSubnets(string title, string description)
    {
        var rows = Subnets
            .Select(subnet => new SubnetOption(subnet.Cidr, subnet.IsSelected))
            .OrderBy(subnet => subnet.Cidr, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var owner = Application.Current?.MainWindow;
        var darkMode = SettingsDarkMode;
        var background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#202124" : "#F4F6F8"));
        var panel = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#2B2D31" : "#FFFFFF"));
        var border = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#50545C" : "#B8C0CC"));
        var text = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#F3F5F7" : "#111827"));
        var muted = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#AEB4BE" : "#526070"));
        var input = new SolidColorBrush((Color)ColorConverter.ConvertFromString(darkMode ? "#1E1F22" : "#FFFFFF"));

        var root = new Grid
        {
            Margin = new Thickness(14),
            Background = background
        };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var intro = new TextBlock
        {
            Text = description,
            TextWrapping = TextWrapping.Wrap,
            Foreground = muted,
            Margin = new Thickness(0, 0, 0, 10)
        };
        root.Children.Add(intro);

        var listPanel = new StackPanel();
        var scroll = new ScrollViewer
        {
            Content = listPanel,
            Height = 230,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Background = panel,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8)
        };
        Grid.SetRow(scroll, 2);
        root.Children.Add(scroll);

        var summary = new TextBlock
        {
            Foreground = muted,
            Margin = new Thickness(0, 8, 0, 10)
        };
        Grid.SetRow(summary, 3);
        root.Children.Add(summary);

        void RefreshSummary()
        {
            summary.Text = $"{rows.Count(row => row.IsSelected)} of {rows.Count} subnet(s) selected";
        }

        void RefreshList()
        {
            listPanel.Children.Clear();
            foreach (var row in rows.OrderBy(row => row.Cidr, StringComparer.OrdinalIgnoreCase))
            {
                var box = new CheckBox
                {
                    Content = row.Cidr,
                    IsChecked = row.IsSelected,
                    Foreground = text,
                    Margin = new Thickness(0, 0, 0, 6)
                };
                box.Checked += (_, _) =>
                {
                    row.IsSelected = true;
                    RefreshSummary();
                };
                box.Unchecked += (_, _) =>
                {
                    row.IsSelected = false;
                    RefreshSummary();
                };
                listPanel.Children.Add(box);
            }

            RefreshSummary();
        }

        var addPanel = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        addPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        addPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        addPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        addPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var addBox = new TextBox
        {
            MinWidth = 230,
            Background = input,
            Foreground = text,
            BorderBrush = border,
            Padding = new Thickness(6, 4, 6, 4),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        addPanel.Children.Add(addBox);

        var addButton = new Button
        {
            Content = "Add",
            MinWidth = 70,
            Margin = new Thickness(8, 0, 0, 0)
        };
        Grid.SetColumn(addButton, 1);
        addPanel.Children.Add(addButton);

        var selectAllButton = new Button
        {
            Content = "Select All",
            MinWidth = 90,
            Margin = new Thickness(8, 0, 0, 0)
        };
        Grid.SetColumn(selectAllButton, 2);
        addPanel.Children.Add(selectAllButton);

        var deselectAllButton = new Button
        {
            Content = "Deselect All",
            MinWidth = 100,
            Margin = new Thickness(8, 0, 0, 0)
        };
        Grid.SetColumn(deselectAllButton, 3);
        addPanel.Children.Add(deselectAllButton);

        Grid.SetRow(addPanel, 1);
        root.Children.Add(addPanel);

        var okButton = new Button
        {
            Content = "Start Scan",
            IsDefault = true,
            MinWidth = 95,
            Margin = new Thickness(0, 0, 8, 0)
        };
        var cancelButton = new Button
        {
            Content = "Cancel",
            IsCancel = true,
            MinWidth = 80
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 2, 0, 0)
        };
        buttons.Children.Add(okButton);
        buttons.Children.Add(cancelButton);
        Grid.SetRow(buttons, 4);
        root.Children.Add(buttons);

        var window = new Window
        {
            Title = title,
            Content = root,
            Width = 520,
            Height = 430,
            MinWidth = 480,
            MinHeight = 390,
            Background = background,
            ResizeMode = ResizeMode.CanResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = owner
        };

        addButton.Click += (_, _) =>
        {
            var cidr = addBox.Text.Trim();
            if (!IsValidCidr(cidr))
            {
                MessageBox.Show(window, "Invalid CIDR. Example: 192.168.20.0/24", "Invalid subnet", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var existing = rows.FirstOrDefault(row => string.Equals(row.Cidr, cidr, StringComparison.OrdinalIgnoreCase));
            if (existing is not null)
            {
                existing.IsSelected = true;
            }
            else
            {
                rows.Add(new SubnetOption(cidr, true));
            }

            addBox.Text = "";
            RefreshList();
        };

        selectAllButton.Click += (_, _) =>
        {
            foreach (var row in rows)
            {
                row.IsSelected = true;
            }

            RefreshList();
        };

        deselectAllButton.Click += (_, _) =>
        {
            foreach (var row in rows)
            {
                row.IsSelected = false;
            }

            RefreshList();
        };

        okButton.Click += (_, _) =>
        {
            if (!rows.Any(row => row.IsSelected))
            {
                MessageBox.Show(window, "Select at least one subnet before scanning.", "Nothing to scan", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            window.DialogResult = true;
        };

        RefreshList();
        addBox.Focus();

        if (window.ShowDialog() != true)
        {
            return null;
        }

        foreach (var row in rows)
        {
            var existing = Subnets.FirstOrDefault(subnet => string.Equals(subnet.Cidr, row.Cidr, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                AddSubnetOption(row.Cidr, row.IsSelected);
            }
            else
            {
                existing.IsSelected = row.IsSelected;
            }
        }

        OnPropertyChanged(nameof(SelectedSubnetSummary));
        RaiseCommandStates();

        return rows
            .Where(row => row.IsSelected)
            .Select(row => row.Cidr)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private async Task<ProvisionCredentialInput?> PromptForProvisionCredentialsAsync(int deviceCount)
    {
        var settings = ReadGuiSettingsFile();
        var defaultUsername = string.IsNullOrWhiteSpace(settings.DefaultUsername)
            ? "admin"
            : settings.DefaultUsername.Trim();
        var defaultPassword = "";
        var loadedSavedPassword = false;

        if (!string.IsNullOrWhiteSpace(settings.ProtectedDefaultPassword))
        {
            try
            {
                defaultPassword = await _backend
                    .UnprotectSettingsPasswordAsync(settings.ProtectedDefaultPassword, CancellationToken.None)
                    .ConfigureAwait(true);
                loadedSavedPassword = !string.IsNullOrEmpty(defaultPassword);
            }
            catch
            {
                StatusText = "Saved default password could not be decrypted. Enter credentials manually.";
            }
        }

        return PromptForProvisionCredentials(deviceCount, defaultUsername, defaultPassword, loadedSavedPassword);
    }

    private static ProvisionCredentialInput? PromptForProvisionCredentials(
        int deviceCount,
        string defaultUsername,
        string defaultPassword,
        bool loadedSavedPassword)
    {
        var usernameBox = new TextBox
        {
            Text = string.IsNullOrWhiteSpace(defaultUsername) ? "admin" : defaultUsername.Trim(),
            MinWidth = 240,
            VerticalContentAlignment = VerticalAlignment.Center
        };
        var passwordBox = new PasswordBox
        {
            Password = defaultPassword ?? "",
            MinWidth = 240
        };
        var confirmPasswordBox = new PasswordBox
        {
            Password = defaultPassword ?? "",
            MinWidth = 240
        };

        var grid = new Grid { Margin = new Thickness(14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var intro = new TextBlock
        {
            Text = loadedSavedPassword
                ? $"Saved default credentials are prefilled. Review the admin account to create on {deviceCount} device(s)."
                : $"Enter the admin account to create on {deviceCount} device(s).",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12)
        };
        Grid.SetColumnSpan(intro, 2);
        grid.Children.Add(intro);

        var usernameLabel = new TextBlock
        {
            Text = "Username",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 8)
        };
        Grid.SetRow(usernameLabel, 1);
        grid.Children.Add(usernameLabel);

        Grid.SetRow(usernameBox, 1);
        Grid.SetColumn(usernameBox, 1);
        usernameBox.Margin = new Thickness(0, 0, 0, 8);
        grid.Children.Add(usernameBox);

        var passwordLabel = new TextBlock
        {
            Text = "Password",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 8)
        };
        Grid.SetRow(passwordLabel, 2);
        grid.Children.Add(passwordLabel);

        Grid.SetRow(passwordBox, 2);
        Grid.SetColumn(passwordBox, 1);
        passwordBox.Margin = new Thickness(0, 0, 0, 8);
        grid.Children.Add(passwordBox);

        var confirmPasswordLabel = new TextBlock
        {
            Text = "Confirm Password",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0)
        };
        Grid.SetRow(confirmPasswordLabel, 3);
        grid.Children.Add(confirmPasswordLabel);

        Grid.SetRow(confirmPasswordBox, 3);
        Grid.SetColumn(confirmPasswordBox, 1);
        grid.Children.Add(confirmPasswordBox);

        var okButton = new Button
        {
            Content = "OK",
            IsDefault = true,
            MinWidth = 80,
            Margin = new Thickness(0, 14, 8, 0)
        };
        var cancelButton = new Button
        {
            Content = "Cancel",
            IsCancel = true,
            MinWidth = 80,
            Margin = new Thickness(0, 14, 0, 0)
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        buttons.Children.Add(okButton);
        buttons.Children.Add(cancelButton);
        Grid.SetRow(buttons, 4);
        Grid.SetColumnSpan(buttons, 2);
        grid.Children.Add(buttons);

        var window = new Window
        {
            Title = "Provision Admin Credentials",
            Content = grid,
            SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Application.Current?.MainWindow
        };

        okButton.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(usernameBox.Text) || string.IsNullOrWhiteSpace(passwordBox.Password))
            {
                MessageBox.Show(window, "Enter both username and password.", "Provision Credentials", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            if (passwordBox.Password != confirmPasswordBox.Password)
            {
                MessageBox.Show(window, "Passwords do not match. Please re-enter and confirm.", "Provision Credentials", MessageBoxButton.OK, MessageBoxImage.Warning);
                confirmPasswordBox.Clear();
                confirmPasswordBox.Focus();
                return;
            }

            window.DialogResult = true;
        };

        usernameBox.SelectAll();
        usernameBox.Focus();

        return window.ShowDialog() == true
            ? new ProvisionCredentialInput(usernameBox.Text.Trim(), passwordBox.Password)
            : null;
    }

    private void OpenSettingsFolder()
    {
        OpenFolder(SettingsDirectory, "Settings folder");
    }

    private void OpenOutputFolder()
    {
        OpenFolder(DataRoot, "Output folder");
    }

    private void OpenFolder(string path, string label)
    {
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo
            {
                FileName = path,
                UseShellExecute = true
            });
            StatusText = $"Opened {label}.";
        }
        catch (Exception ex)
        {
            StatusText = $"{label} open failed: {ex.Message}";
            MessageBox.Show(ex.Message, $"{label} open failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void SetAllSubnets(bool selected)
    {
        foreach (var subnet in Subnets)
        {
            subnet.IsSelected = selected;
        }

        OnPropertyChanged(nameof(SelectedSubnetSummary));
    }

    private void LoadProvisionFromScan()
    {
        ProvisionRows.Clear();
        foreach (var scanRow in ScanResults.Where(r => !string.IsNullOrWhiteSpace(r.IP)).OrderBy(r => r.IP, StringComparer.OrdinalIgnoreCase))
        {
            AddProvisionRow(new ProvisionDeviceRow
            {
                IP = scanRow.IP,
                Selected = scanRow.Selected,
                Status = "Pending"
            });
        }

        OnPropertyChanged(nameof(ProvisionSummary));
        StatusText = $"Loaded {ProvisionRows.Count} device(s) into Provision.";
    }

    private void LoadBlanketFromProvision()
    {
        BlanketRows.Clear();
        foreach (var provisionRow in ProvisionRows
                     .Where(r => !string.IsNullOrWhiteSpace(r.IP) && string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase))
                     .OrderBy(r => r.IP, StringComparer.OrdinalIgnoreCase))
        {
            AddBlanketRow(new BlanketDeviceRow
            {
                IP = provisionRow.IP,
                Selected = provisionRow.Selected,
                Status = "Pending"
            });
        }

        OnPropertyChanged(nameof(BlanketSummary));
        StatusText = $"Loaded {BlanketRows.Count} device(s) into Blanket Settings.";
    }

    private async Task AddBlanketDevicesAsync()
    {
        var ips = ParseIpList(BlanketDeviceInput, out var invalid);
        if (invalid.Length > 0)
        {
            MessageBox.Show($"These entries are not valid IP addresses: {string.Join(", ", invalid)}", "Invalid device IP", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (ips.Length == 0)
        {
            MessageBox.Show("Enter at least one device IP address.", "No devices", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var targets = AddOrSelectBlanketDevices(ips);
        BlanketDeviceInput = "";
        StatusText = $"Added {targets.Length} device(s) to Blanket Settings.";
        await FetchBlanketCapabilitiesForRowsAsync(targets).ConfigureAwait(true);
    }

    private async Task LoadBlanketFromScanAsync()
    {
        var ips = ScanResults
            .Where(r => r.Selected && !string.IsNullOrWhiteSpace(r.IP))
            .Select(r => r.IP)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (ips.Length == 0)
        {
            MessageBox.Show("Select at least one scanned device first.", "No scanned devices selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var targets = AddOrSelectBlanketDevices(ips);
        StatusText = $"Loaded {targets.Length} scanned device(s) into Blanket Settings.";
        await FetchBlanketCapabilitiesForRowsAsync(targets).ConfigureAwait(true);
    }

    private async Task ScanAndLoadBlanketAsync()
    {
        var selectedCidrs = PromptForScanSubnets(
            "Blanket Settings Scan Subnets",
            "Choose the subnet(s) to scan for reachable devices, then load them into Blanket Settings.");
        if (selectedCidrs is null)
        {
            StatusText = "Blanket Settings scan cancelled.";
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            ProgressText = "Starting reachable-device scan...";
            StatusText = $"Scanning {selectedCidrs.Length} subnet(s) for reachable devices...";

            var rows = await _backend.ScanReachableDevicesAsync(selectedCidrs, progress, _scanCancellation.Token).ConfigureAwait(true);
            var targets = AddOrSelectBlanketDevices(rows.Select(r => r.IP));
            foreach (var target in targets)
            {
                var scanRow = rows.FirstOrDefault(r => string.Equals(r.IP, target.IP, StringComparison.OrdinalIgnoreCase));
                if (scanRow is not null)
                {
                    target.Detail = $"Discovered: {scanRow.MatchedSig}";
                    target.Timestamp = scanRow.ScannedAt;
                }
            }

            ProgressText = $"Reachable scan complete. Found {targets.Length} device(s).";
            StatusText = $"Reachable scan complete. Found {targets.Length} device(s).";

            if (targets.Length > 0)
            {
                await FetchBlanketCapabilitiesForRowsAsync(targets).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            ProgressText = "Reachable scan cancelled.";
            StatusText = "Reachable scan cancelled.";
        }
        catch (Exception ex)
        {
            ProgressText = "Reachable scan failed.";
            StatusText = $"Reachable scan failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Reachable scan failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(BlanketSummary));
        }
    }

    private void ClearBlanketDevices()
    {
        BlanketRows.Clear();
        GlobalEdidNameOptions.Clear();
        GlobalEdidName = "";
        OnPropertyChanged(nameof(BlanketSummary));
        StatusText = "Cleared Blanket Settings devices.";
    }

    private BlanketDeviceRow[] AddOrSelectBlanketDevices(IEnumerable<string> ips)
    {
        var byIp = BlanketRows.ToDictionary(row => row.IP, StringComparer.OrdinalIgnoreCase);
        var targets = new List<BlanketDeviceRow>();

        foreach (var ip in ips.Select(ip => ip.Trim()).Where(ip => !string.IsNullOrWhiteSpace(ip)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!byIp.TryGetValue(ip, out var row))
            {
                row = new BlanketDeviceRow
                {
                    IP = ip,
                    Selected = true,
                    Status = "Pending"
                };
                AddBlanketRow(row);
                byIp[ip] = row;
            }

            row.Selected = true;
            targets.Add(row);
        }

        OnPropertyChanged(nameof(BlanketSummary));
        return targets.ToArray();
    }

    private async Task AddPerDeviceDevicesAsync()
    {
        var ips = ParseIpList(PerDeviceInput, out var invalid);
        if (invalid.Length > 0)
        {
            MessageBox.Show($"These entries are not valid IP addresses: {string.Join(", ", invalid)}", "Invalid device IP", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (ips.Length == 0)
        {
            MessageBox.Show("Enter at least one device IP address.", "No devices", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var targets = AddOrSelectPerDeviceRows(ips);
        PerDeviceInput = "";
        StatusText = $"Added {targets.Length} device(s) to Per Device.";
        await FetchPerDeviceStateForRowsAsync(targets).ConfigureAwait(true);
    }

    private async Task ScanAndLoadPerDeviceAsync()
    {
        var selectedCidrs = PromptForScanSubnets(
            "Per Device Scan Subnets",
            "Choose the subnet(s) to scan for reachable devices, then load them into Per Device.");
        if (selectedCidrs is null)
        {
            StatusText = "Per Device scan cancelled.";
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            ProgressText = "Starting reachable-device scan...";
            StatusText = $"Scanning {selectedCidrs.Length} subnet(s) for Per Device...";
            var rows = await _backend.ScanReachableDevicesAsync(selectedCidrs, progress, _scanCancellation.Token).ConfigureAwait(true);
            var targets = AddOrSelectPerDeviceRows(rows.Select(r => r.IP));
            ProgressText = $"Reachable scan complete. Found {targets.Length} device(s).";
            StatusText = $"Reachable scan complete. Found {targets.Length} device(s).";

            if (targets.Length > 0)
            {
                await FetchPerDeviceStateForRowsAsync(targets).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            ProgressText = "Per Device scan cancelled.";
            StatusText = "Per Device scan cancelled.";
        }
        catch (Exception ex)
        {
            ProgressText = "Per Device scan failed.";
            StatusText = $"Per Device scan failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Per Device scan failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(PerDeviceSummary));
        }
    }

    private async Task LoadPerDeviceFromBlanketAsync()
    {
        var ips = BlanketRows
            .Where(r => !string.IsNullOrWhiteSpace(r.IP))
            .Select(r => r.IP)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (ips.Length == 0)
        {
            MessageBox.Show("No Blanket Settings devices are loaded.", "No devices", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var targets = AddOrSelectPerDeviceRows(ips);
        StatusText = $"Loaded {targets.Length} Blanket device(s) into Per Device.";
        await FetchPerDeviceStateForRowsAsync(targets).ConfigureAwait(true);
    }

    private async Task LoadPerDeviceFromProvisionAsync()
    {
        var ips = ProvisionRows
            .Where(r => !string.IsNullOrWhiteSpace(r.IP) && string.Equals(r.Success, "True", StringComparison.OrdinalIgnoreCase))
            .Select(r => r.IP)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (ips.Length == 0)
        {
            MessageBox.Show("No successful provision rows are loaded.", "No devices", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var targets = AddOrSelectPerDeviceRows(ips);
        StatusText = $"Loaded {targets.Length} provisioned device(s) into Per Device.";
        await FetchPerDeviceStateForRowsAsync(targets).ConfigureAwait(true);
    }

    private async Task FetchPerDeviceStateAsync()
    {
        var selectedRows = PerDeviceRows.Where(r => r.Selected).ToArray();
        if (selectedRows.Length == 0)
        {
            MessageBox.Show("Select at least one device before fetching state.", "Nothing selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        await FetchPerDeviceStateForRowsAsync(selectedRows).ConfigureAwait(true);
    }

    private async Task FetchPerDeviceStateForRowsAsync(IReadOnlyCollection<PerDeviceDeviceRow> selectedRows)
    {
        if (selectedRows.Count == 0)
        {
            return;
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            foreach (var row in selectedRows)
            {
                row.Status = "Working";
                row.Detail = "";
                row.Timestamp = "";
            }

            ProgressText = $"Fetching per-device state for {selectedRows.Count} device(s)...";
            StatusText = $"Fetching per-device state for {selectedRows.Count} device(s)...";
            var result = await _backend.FetchPerDeviceStateAsync(selectedRows.Select(r => r.IP), _sessionUsername, _sessionPassword, progress, _scanCancellation.Token).ConfigureAwait(true);
            ApplyPerDeviceResults(result);
            ProgressText = "Per Device fetch complete.";
            StatusText = "Per Device fetch complete.";
        }
        catch (OperationCanceledException)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Cancelled";
            }

            ProgressText = "Per Device fetch cancelled.";
            StatusText = "Per Device fetch cancelled.";
        }
        catch (Exception ex)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Error";
                row.Detail = ex.Message;
            }

            ProgressText = "Per Device fetch failed.";
            StatusText = $"Per Device fetch failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Per Device fetch failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(PerDeviceSummary));
        }
    }

    private async Task ApplyPerDeviceChangesAsync(bool promptForReboot, bool skipConfirm = false)
    {
        var selectedIps = PerDeviceRows.Where(r => r.Selected).Select(r => r.IP).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var selectedRows = PerDeviceRows.Where(r => r.Selected && r.HasChanges).ToArray();
        var selectedAvRows = PerDeviceAvRows.Where(r => selectedIps.Contains(r.IP) && r.HasChanges).ToArray();
        var selectedMulticastRows = PerDeviceMulticastRows.Where(r => selectedIps.Contains(r.IP) && r.HasChanges).ToArray();
        var selectedControlSubnetRows = PerDeviceControlSubnetRows.Where(r => selectedIps.Contains(r.IP) && r.HasChanges).ToArray();
        var changeCount = selectedRows.Length + selectedAvRows.Length + selectedMulticastRows.Length + selectedControlSubnetRows.Length;
        if (changeCount == 0)
        {
            if (!skipConfirm)
            {
                MessageBox.Show("Select at least one device with changes before applying.", "Nothing to apply", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            return;
        }

        if (!skipConfirm)
        {
            var confirm = MessageBox.Show(
                $"Apply {changeCount} per-device change row(s)?",
                "Confirm Per Device Changes",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (confirm != MessageBoxResult.Yes)
            {
                StatusText = "Per Device apply cancelled.";
                return;
            }
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        try
        {
            IsBusy = true;
            foreach (var row in PerDeviceRows.Where(r => selectedIps.Contains(r.IP)))
            {
                row.Status = "Working";
                row.Detail = "";
                row.Timestamp = "";
            }

            ProgressText = $"Applying per-device changes to {selectedIps.Count} device(s)...";
            StatusText = $"Applying per-device changes to {selectedIps.Count} device(s)...";
            var result = await _backend.ApplyPerDeviceChangesAsync(
                PerDeviceRows.Where(r => selectedIps.Contains(r.IP)),
                PerDeviceAvRows.Where(r => selectedIps.Contains(r.IP)),
                PerDeviceMulticastRows.Where(r => selectedIps.Contains(r.IP)),
                PerDeviceControlSubnetRows.Where(r => selectedIps.Contains(r.IP)),
                _sessionUsername,
                _sessionPassword,
                progress,
                _scanCancellation.Token).ConfigureAwait(true);
            ApplyPerDeviceResults(result);
            ProgressText = "Per Device apply complete.";
            StatusText = "Per Device apply complete. Saved crestron-perdevice.csv.";

            if (promptForReboot)
            {
                await PromptForRebootNeededAsync(
                    "Per Device",
                    PerDeviceRows.Where(r => selectedIps.Contains(r.IP) && r.NeedsReboot).Select(r => r.IP),
                    () => RebootSelectedPerDeviceAsync(onlyMarkedReboot: true, confirm: false)).ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Cancelled";
            }

            ProgressText = "Per Device apply cancelled.";
            StatusText = "Per Device apply cancelled.";
        }
        catch (Exception ex)
        {
            foreach (var row in selectedRows.Where(r => r.Status == "Working"))
            {
                row.Status = "Error";
                row.Detail = ex.Message;
            }

            ProgressText = "Per Device apply failed.";
            StatusText = $"Per Device apply failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Per Device apply failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
            OnPropertyChanged(nameof(PerDeviceSummary));
        }
    }

    private async Task PromptForRebootNeededAsync(string areaName, IEnumerable<string> ips, Func<Task> rebootAction)
    {
        var rebootIps = ips
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (rebootIps.Length == 0)
        {
            return;
        }

        var confirm = MessageBox.Show(
            $"{rebootIps.Length} {areaName} device(s) need a reboot. Reboot them now?",
            "Reboot Needed",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirm == MessageBoxResult.Yes)
        {
            await rebootAction().ConfigureAwait(true);
        }
    }

    private Task RebootSelectedProvisionAsync()
    {
        var rows = ProvisionRows.Where(r => r.Selected).ToArray();
        return RebootSelectedIpsAsync(
            "Provision",
            rows.Select(r => r.IP),
            result =>
            {
                var row = rows.FirstOrDefault(r => string.Equals(r.IP, result.IP, StringComparison.OrdinalIgnoreCase));
                if (row is null)
                {
                    return;
                }

                row.Status = result.Success ? "Rebooting" : "Reboot failed";
                row.Success = result.Success ? "True" : "False";
                row.Response = result.Success ? "Reboot command accepted." : result.Response;
                row.Timestamp = result.Timestamp;
            },
            confirm: true);
    }

    private Task RebootSelectedBlanketAsync(bool onlyMarkedReboot = false, bool confirm = true)
    {
        var rows = BlanketRows
            .Where(r => r.Selected && (!onlyMarkedReboot || r.NeedsReboot))
            .ToArray();

        return RebootSelectedIpsAsync(
            "Blanket Settings",
            rows.Select(r => r.IP),
            result =>
            {
                var row = rows.FirstOrDefault(r => string.Equals(r.IP, result.IP, StringComparison.OrdinalIgnoreCase));
                if (row is null)
                {
                    return;
                }

                row.Status = result.Success ? "Rebooting" : "Reboot failed";
                row.Detail = result.Success ? "Reboot command accepted." : result.Response;
                row.NeedsReboot = !result.Success;
                row.Timestamp = result.Timestamp;
            },
            confirm);
    }

    private Task RebootSelectedPerDeviceAsync(bool onlyMarkedReboot = false, bool confirm = true)
    {
        var rows = PerDeviceRows
            .Where(r => r.Selected && (!onlyMarkedReboot || r.NeedsReboot))
            .ToArray();
        var rowsByRebootIp = rows
            .GroupBy(GetEffectiveFetchIp, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.OrdinalIgnoreCase);

        return RebootSelectedIpsAsync(
            "Per Device",
            rowsByRebootIp.Keys,
            result =>
            {
                if (!rowsByRebootIp.TryGetValue(result.IP, out var row))
                {
                    row = rows.FirstOrDefault(r => string.Equals(r.IP, result.IP, StringComparison.OrdinalIgnoreCase));
                    if (row is null)
                    {
                        return;
                    }
                }

                row.Status = result.Success ? "Rebooting" : "Reboot failed";
                row.Detail = result.Success ? "Reboot command accepted." : result.Response;
                row.NeedsReboot = !result.Success;
                row.Timestamp = result.Timestamp;
            },
            confirm);
    }

    private async Task RebootSelectedIpsAsync(string areaName, IEnumerable<string> ips, Action<RebootDeviceResult> applyResult, bool confirm)
    {
        var rebootIps = ips
            .Where(ip => !string.IsNullOrWhiteSpace(ip))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (rebootIps.Length == 0)
        {
            MessageBox.Show("Select at least one device to reboot.", "Nothing selected", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (confirm)
        {
            var response = MessageBox.Show(
                $"Send reboot command to {rebootIps.Length} selected {areaName} device(s)?",
                "Confirm Reboot",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (response != MessageBoxResult.Yes)
            {
                StatusText = "Reboot cancelled.";
                return;
            }
        }

        _scanCancellation = new CancellationTokenSource();
        var progress = new Progress<string>(message =>
        {
            if (!string.IsNullOrWhiteSpace(message))
            {
                ProgressText = message.Trim();
            }
        });

        var accepted = 0;
        var errors = 0;

        try
        {
            IsBusy = true;
            ProgressText = $"Sending reboot commands to {rebootIps.Length} device(s)...";
            StatusText = $"Sending reboot commands to {rebootIps.Length} device(s)...";

            var results = await _backend.RebootDevicesAsync(rebootIps, _sessionUsername, _sessionPassword, progress, _scanCancellation.Token).ConfigureAwait(true);
            foreach (var result in results)
            {
                applyResult(result);
            }

            accepted = results.Count(r => r.Success);
            errors = results.Count(r => !r.Success);
            ProgressText = $"Reboot command accepted by {accepted} of {rebootIps.Length} device(s).";
            StatusText = ProgressText;
            OnPropertyChanged(nameof(ProvisionSummary));
            OnPropertyChanged(nameof(BlanketSummary));
            OnPropertyChanged(nameof(PerDeviceSummary));
        }
        catch (OperationCanceledException)
        {
            ProgressText = "Reboot cancelled.";
            StatusText = "Reboot cancelled.";
        }
        catch (Exception ex)
        {
            ProgressText = "Reboot failed.";
            StatusText = $"Reboot failed: {ex.Message}";
            MessageBox.Show(ex.Message, "Reboot failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _scanCancellation?.Dispose();
            _scanCancellation = null;
            IsBusy = false;
        }

        if (accepted > 0)
        {
            await WaitForWorkflowRebootAsync(accepted, errors).ConfigureAwait(true);

            // After the wait, auto-fetch state for rebooted devices.
            // Rows whose IP was changed to a new static address are re-keyed first.
            var (blanketTargets, perDeviceTargets) = PromoteNewIpsAfterReboot(rebootIps);

            if (blanketTargets.Count > 0)
            {
                await FetchBlanketCapabilitiesForRowsAsync(blanketTargets).ConfigureAwait(true);
            }

            if (perDeviceTargets.Count > 0)
            {
                await FetchPerDeviceStateForRowsAsync(perDeviceTargets).ConfigureAwait(true);
            }
        }
    }

    private PerDeviceDeviceRow[] AddOrSelectPerDeviceRows(IEnumerable<string> ips)
    {
        var byIp = PerDeviceRows.ToDictionary(row => row.IP, StringComparer.OrdinalIgnoreCase);
        var targets = new List<PerDeviceDeviceRow>();

        foreach (var ip in ips.Select(ip => ip.Trim()).Where(ip => !string.IsNullOrWhiteSpace(ip)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!byIp.TryGetValue(ip, out var row))
            {
                row = new PerDeviceDeviceRow
                {
                    IP = ip,
                    Selected = true,
                    Status = "Pending"
                };
                AddPerDeviceRow(row);
                byIp[ip] = row;
            }

            row.Selected = true;
            targets.Add(row);
        }

        OnPropertyChanged(nameof(PerDeviceSummary));
        return targets.ToArray();
    }

    private void ClearPerDeviceRows()
    {
        PerDeviceRows.Clear();
        PerDeviceAvRows.Clear();
        PerDeviceMulticastRows.Clear();
        PerDeviceControlSubnetRows.Clear();
        OnPropertyChanged(nameof(PerDeviceSummary));
        StatusText = "Cleared Per Device devices.";
    }

    private void SetAllPerDeviceRows(bool selected)
    {
        foreach (var row in PerDeviceRows)
        {
            row.Selected = selected;
        }

        OnPropertyChanged(nameof(PerDeviceSummary));
    }

    private void SetAllProvisionRows(bool selected)
    {
        foreach (var row in ProvisionRows)
        {
            row.Selected = selected;
        }

        OnPropertyChanged(nameof(ProvisionSummary));
    }

    private void SetAllBlanketRows(bool selected)
    {
        foreach (var row in BlanketRows)
        {
            row.Selected = selected;
        }

        OnPropertyChanged(nameof(BlanketSummary));
    }

    private bool CanStartScan()
    {
        return !IsBusy && Subnets.Count > 0;
    }

    private bool CanProvisionSelected()
    {
        return !IsBusy && ProvisionRows.Any(r => r.Selected);
    }

    private bool CanApplyBlanketSettings()
    {
        return !IsBusy && BlanketRows.Any(r => r.Selected) && BuildBlanketOptions().HasAnySelection;
    }

    private bool CanApplyPerDeviceChanges()
    {
        if (IsBusy)
        {
            return false;
        }

        var selectedIps = PerDeviceRows.Where(r => r.Selected).Select(r => r.IP).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return PerDeviceRows.Any(r => r.Selected && r.HasChanges) ||
               PerDeviceAvRows.Any(r => selectedIps.Contains(r.IP) && r.HasChanges) ||
               PerDeviceMulticastRows.Any(r => selectedIps.Contains(r.IP) && r.HasChanges) ||
               PerDeviceControlSubnetRows.Any(r => selectedIps.Contains(r.IP) && r.HasChanges);
    }

    private void LoadSettingsForEditor()
    {
        var settings = ReadGuiSettingsFile();
        SettingsDefaultUsername = settings.DefaultUsername ?? "";
        SettingsDefaultPassword = "";
        SettingsConfirmPassword = "";
        SettingsDarkMode = settings.DarkMode;
        SettingsHasSavedPassword = !string.IsNullOrWhiteSpace(settings.ProtectedDefaultPassword);
        SettingsMostUsedSubnets = string.Join(
            Environment.NewLine,
            (settings.MostUsedSubnets ?? new List<string>())
                .Where(IsValidCidr)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Order(StringComparer.OrdinalIgnoreCase));
        SettingsStatus = "";
    }

    private async Task SaveSettingsAsync()
    {
        var subnets = ParseSettingsSubnets(SettingsMostUsedSubnets, out var invalid);
        if (invalid.Length > 0)
        {
            MessageBox.Show(
                "These subnets are not valid CIDR entries:" + Environment.NewLine + string.Join(Environment.NewLine, invalid),
                "Invalid Subnets",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        if (subnets.Length == 0)
        {
            MessageBox.Show("Enter at least one Most Used Subnet.", "Settings", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (!string.IsNullOrEmpty(SettingsDefaultPassword) && SettingsDefaultPassword != SettingsConfirmPassword)
        {
            SettingsStatus = "Passwords do not match.";
            return;
        }

        var existing = ReadGuiSettingsFile();
        var protectedPassword = existing.ProtectedDefaultPassword ?? "";
        if (!string.IsNullOrEmpty(SettingsDefaultPassword))
        {
            IsBusy = true;
            SettingsStatus = "Encrypting password...";
            try
            {
                protectedPassword = await _backend.ProtectSettingsPasswordAsync(SettingsDefaultPassword, CancellationToken.None).ConfigureAwait(true);
            }
            finally
            {
                IsBusy = false;
            }
        }

        var settings = new GuiSettingsFile
        {
            DefaultUsername = SettingsDefaultUsername.Trim(),
            ProtectedDefaultPassword = protectedPassword,
            DarkMode = SettingsDarkMode,
            MostUsedSubnets = subnets.ToList()
        };

        WriteGuiSettingsFile(settings);
        SettingsDefaultPassword = "";
        SettingsConfirmPassword = "";
        SettingsHasSavedPassword = !string.IsNullOrWhiteSpace(settings.ProtectedDefaultPassword);
        SettingsMostUsedSubnets = string.Join(Environment.NewLine, subnets);
        ReloadSubnetOptions(subnets);
        SettingsStatus = "Settings saved.";
        StatusText = "Settings saved.";
    }

    private void ClearSettingsPassword()
    {
        var settings = ReadGuiSettingsFile();
        settings.DefaultUsername = SettingsDefaultUsername.Trim();
        settings.ProtectedDefaultPassword = "";
        settings.DarkMode = SettingsDarkMode;
        settings.MostUsedSubnets = ParseSettingsSubnets(SettingsMostUsedSubnets, out var invalid).ToList();

        if (invalid.Length > 0)
        {
            MessageBox.Show(
                "Fix invalid subnet entries before clearing the password:" + Environment.NewLine + string.Join(Environment.NewLine, invalid),
                "Invalid Subnets",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        WriteGuiSettingsFile(settings);
        SettingsDefaultPassword = "";
        SettingsConfirmPassword = "";
        SettingsHasSavedPassword = false;
        SettingsStatus = "Saved password cleared.";
        StatusText = "Saved password cleared.";
    }

    private void ReloadSubnetOptions(IEnumerable<string> cidrs)
    {
        Subnets.Clear();
        foreach (var cidr in cidrs.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c, StringComparer.OrdinalIgnoreCase))
        {
            AddSubnetOption(cidr, true);
        }

        OnPropertyChanged(nameof(SelectedSubnetSummary));
    }

    private GuiSettingsFile ReadGuiSettingsFile()
    {
        var path = SettingsPath;
        if (!File.Exists(path))
        {
            return new GuiSettingsFile();
        }

        try
        {
            return JsonSerializer.Deserialize<GuiSettingsFile>(
                File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new GuiSettingsFile();
        }
        catch
        {
            return new GuiSettingsFile();
        }
    }

    private void WriteGuiSettingsFile(GuiSettingsFile settings)
    {
        var path = SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? RepoRoot);
        var json = JsonSerializer.Serialize(
            settings,
            new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    private static string[] ParseSettingsSubnets(string value, out string[] invalid)
    {
        var tokens = value
            .Split(['\r', '\n', ',', ';', '\t', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(token => token.Split('#')[0].Trim())
            .Where(token => !string.IsNullOrWhiteSpace(token))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        invalid = tokens.Where(token => !IsValidCidr(token)).ToArray();
        return tokens.Where(IsValidCidr).ToArray();
    }

    private void LoadSubnets()
    {
        var cidrs = LoadGuiSettingsSubnets();

        if (cidrs.Count == 0)
        {
            var subnetsFile = Path.Combine(DataRoot, "subnets.txt");
            if (!File.Exists(subnetsFile))
            {
                subnetsFile = Path.Combine(RepoRoot, "subnets.txt");
            }

            if (File.Exists(subnetsFile))
            {
                cidrs.AddRange(File.ReadLines(subnetsFile)
                    .Select(line => line.Split('#')[0].Trim())
                    .Where(IsValidCidr));
            }
        }

        if (cidrs.Count == 0)
        {
            cidrs.Add("192.168.20.0/24");
        }

        foreach (var cidr in cidrs.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c, StringComparer.OrdinalIgnoreCase))
        {
            AddSubnetOption(cidr, true);
        }

        OnPropertyChanged(nameof(SelectedSubnetSummary));
    }

    private List<string> LoadGuiSettingsSubnets()
    {
        var path = SettingsPath;
        if (!File.Exists(path))
        {
            return new List<string>();
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("MostUsedSubnets", out var subnets) ||
                subnets.ValueKind != JsonValueKind.Array)
            {
                return new List<string>();
            }

            return subnets.EnumerateArray()
                .Select(e => e.GetString()?.Trim() ?? "")
                .Where(IsValidCidr)
                .ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    private void AddSubnetOption(string cidr, bool isSelected)
    {
        var option = new SubnetOption(cidr, isSelected);
        option.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(SubnetOption.IsSelected))
            {
                OnPropertyChanged(nameof(SelectedSubnetSummary));
                RaiseCommandStates();
            }
        };

        Subnets.Add(option);
    }

    private void AddProvisionRow(ProvisionDeviceRow row)
    {
        row.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(ProvisionDeviceRow.Selected)
                or nameof(ProvisionDeviceRow.Status)
                or nameof(ProvisionDeviceRow.Success))
            {
                OnPropertyChanged(nameof(ProvisionSummary));
                RaiseCommandStates();
            }
        };

        ProvisionRows.Add(row);
    }

    private void AddBlanketRow(BlanketDeviceRow row)
    {
        row.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(BlanketDeviceRow.Selected)
                or nameof(BlanketDeviceRow.Status)
                or nameof(BlanketDeviceRow.NeedsReboot))
            {
                OnPropertyChanged(nameof(BlanketSummary));
                RaiseCommandStates();
            }
        };

        BlanketRows.Add(row);
    }

    private void AddPerDeviceRow(PerDeviceDeviceRow row)
    {
        row.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PerDeviceSummary));
            RaiseCommandStates();
        };

        PerDeviceRows.Add(row);
    }

    private void AddPerDeviceAvRow(PerDeviceAvRow row)
    {
        row.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PerDeviceSummary));
            RaiseCommandStates();
        };

        PerDeviceAvRows.Add(row);
    }

    private void AddPerDeviceMulticastRow(PerDeviceMulticastRow row)
    {
        row.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PerDeviceSummary));
            RaiseCommandStates();
        };

        PerDeviceMulticastRows.Add(row);
    }

    private void AddPerDeviceControlSubnetRow(PerDeviceControlSubnetRow row)
    {
        row.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(PerDeviceSummary));
            RaiseCommandStates();
        };

        PerDeviceControlSubnetRows.Add(row);
    }

    private void ApplyBlanketResults(IEnumerable<BlanketDeviceRow> results)
    {
        var byIp = BlanketRows.ToDictionary(row => row.IP, StringComparer.OrdinalIgnoreCase);
        foreach (var result in results)
        {
            if (!byIp.TryGetValue(result.IP, out var row))
            {
                AddBlanketRow(result);
                continue;
            }

            row.Model = result.Model;
            row.Hostname = result.Hostname;
            row.CurrentDeviceMode = result.CurrentDeviceMode;
            row.AvApiFamily = result.AvApiFamily;
            row.AvApiVersion = result.AvApiVersion;
            row.SupportsAvSettings = result.SupportsAvSettings;
            row.SupportsGlobalEdid = result.SupportsGlobalEdid;
            row.EdidNames = result.EdidNames;
            row.SupportsNtp = result.SupportsNtp;
            row.SupportsCloud = result.SupportsCloud;
            row.SupportsFusion = result.SupportsFusion;
            row.SupportsAutoUpdate = result.SupportsAutoUpdate;
            row.SupportsDisplaySettings = result.SupportsDisplaySettings;
            row.SupportsToolbarSettings = result.SupportsToolbarSettings;
            row.SupportsAvFrameworkSettings = result.SupportsAvFrameworkSettings;
            row.CapabilitiesFetched = result.CapabilitiesFetched;
            row.Status = result.Status;
            row.Detail = result.Detail;
            row.NeedsReboot = result.NeedsReboot;
            row.Timestamp = result.Timestamp;
        }

        RefreshGlobalEdidNameOptions();
        OnPropertyChanged(nameof(BlanketSummary));
    }

    private void ApplyPerDeviceResults(PerDeviceStateResult result)
    {
        var results = result.DeviceRows;
        var fetchedIps = results
            .Where(row => !string.IsNullOrWhiteSpace(row.IP))
            .Select(row => row.IP)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        if (fetchedIps.Count > 0)
        {
            RemovePerDeviceAvRowsByIp(fetchedIps);
        }

        var byIp = PerDeviceRows.ToDictionary(row => row.IP, StringComparer.OrdinalIgnoreCase);
        foreach (var rowResult in results)
        {
            if (!byIp.TryGetValue(rowResult.IP, out var row))
            {
                AddPerDeviceRow(rowResult);
                continue;
            }

            row.Model = rowResult.Model;
            row.CurrentHostname = rowResult.CurrentHostname;
            row.NewHostname = rowResult.NewHostname;
            row.SupportsNetwork = rowResult.SupportsNetwork;
            row.SupportsIpTable = rowResult.SupportsIpTable;
            row.HasWifi = rowResult.HasWifi;
            row.SupportsDisplaySettings = rowResult.SupportsDisplaySettings;
            row.SupportsToolbarSettings = rowResult.SupportsToolbarSettings;
            row.SupportsAvFrameworkSettings = rowResult.SupportsAvFrameworkSettings;
            row.IPMode = rowResult.IPMode;
            row.CurrentIP = rowResult.CurrentIP;
            row.NewIP = rowResult.NewIP;
            row.CurrentSubnet = rowResult.CurrentSubnet;
            row.SubnetMask = rowResult.SubnetMask;
            row.CurrentGateway = rowResult.CurrentGateway;
            row.Gateway = rowResult.Gateway;
            row.CurrentDns1 = rowResult.CurrentDns1;
            row.PrimaryDns = rowResult.PrimaryDns;
            row.CurrentDns2 = rowResult.CurrentDns2;
            row.SecondaryDns = rowResult.SecondaryDns;
            row.DisableWifi = rowResult.DisableWifi;
            row.CurrentAutoBrightness = rowResult.CurrentAutoBrightness;
            row.NewAutoBrightness = rowResult.NewAutoBrightness;
            row.CurrentBrightness = rowResult.CurrentBrightness;
            row.NewBrightness = rowResult.NewBrightness;
            row.CurrentScreensaver = rowResult.CurrentScreensaver;
            row.NewScreensaver = rowResult.NewScreensaver;
            row.CurrentStandbyTimeout = rowResult.CurrentStandbyTimeout;
            row.NewStandbyTimeout = rowResult.NewStandbyTimeout;
            row.CurrentToolbar = rowResult.CurrentToolbar;
            row.NewToolbar = rowResult.NewToolbar;
            row.CurrentAvFramework = rowResult.CurrentAvFramework;
            row.NewAvFramework = rowResult.NewAvFramework;
            row.CurrentIpId = rowResult.CurrentIpId;
            row.NewIpId = rowResult.NewIpId;
            row.CurrentControlSystemAddr = rowResult.CurrentControlSystemAddr;
            row.NewControlSystemAddr = rowResult.NewControlSystemAddr;
            row.Status = rowResult.Status;
            row.Detail = rowResult.Detail;
            row.NeedsReboot = rowResult.NeedsReboot;
            row.Timestamp = rowResult.Timestamp;
        }

        foreach (var avRow in result.AvRows)
        {
            AddPerDeviceAvRow(avRow);
        }

        foreach (var multicastRow in result.MulticastRows)
        {
            AddPerDeviceMulticastRow(multicastRow);
        }

        foreach (var controlSubnetRow in result.ControlSubnetRows)
        {
            AddPerDeviceControlSubnetRow(controlSubnetRow);
        }

        // Remove any secondary rows whose device IP is no longer in the main PerDeviceRows list.
        // This prevents stale rows accumulating when a smaller subset is fetched.
        RemoveOrphanedAvRows();

        OnPropertyChanged(nameof(PerDeviceSummary));
    }

    private void RemoveOrphanedAvRows()
    {
        var knownIps = PerDeviceRows.Select(r => r.IP).ToHashSet(StringComparer.OrdinalIgnoreCase);

        for (var i = PerDeviceAvRows.Count - 1; i >= 0; i--)
            if (!knownIps.Contains(PerDeviceAvRows[i].IP))
                PerDeviceAvRows.RemoveAt(i);

        for (var i = PerDeviceMulticastRows.Count - 1; i >= 0; i--)
            if (!knownIps.Contains(PerDeviceMulticastRows[i].IP))
                PerDeviceMulticastRows.RemoveAt(i);

        for (var i = PerDeviceControlSubnetRows.Count - 1; i >= 0; i--)
            if (!knownIps.Contains(PerDeviceControlSubnetRows[i].IP))
                PerDeviceControlSubnetRows.RemoveAt(i);
    }

    private void RemovePerDeviceAvRowsByIp(ISet<string> ips)
    {
        for (var i = PerDeviceAvRows.Count - 1; i >= 0; i--)
        {
            if (ips.Contains(PerDeviceAvRows[i].IP))
            {
                PerDeviceAvRows.RemoveAt(i);
            }
        }

        for (var i = PerDeviceMulticastRows.Count - 1; i >= 0; i--)
        {
            if (ips.Contains(PerDeviceMulticastRows[i].IP))
            {
                PerDeviceMulticastRows.RemoveAt(i);
            }
        }

        for (var i = PerDeviceControlSubnetRows.Count - 1; i >= 0; i--)
        {
            if (ips.Contains(PerDeviceControlSubnetRows[i].IP))
            {
                PerDeviceControlSubnetRows.RemoveAt(i);
            }
        }
    }

    private void OnSubnetsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(SelectedSubnetSummary));
        RaiseCommandStates();
    }

    private void OnScanResultsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(ScanSummary));
        RaiseCommandStates();
    }

    private void OnProvisionRowsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(ProvisionSummary));
        RaiseCommandStates();
    }

    private void OnBlanketRowsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(BlanketSummary));
        RaiseCommandStates();
    }

    private void OnPerDeviceRowsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(PerDeviceSummary));
        RaiseCommandStates();
    }

    private void OnPerDeviceAvRowsChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        OnPropertyChanged(nameof(PerDeviceSummary));
        RaiseCommandStates();
    }

    private void RaiseCommandStates()
    {
        StartWorkflowCommand.RaiseCanExecuteChanged();
        ContinueWorkflowCommand.RaiseCanExecuteChanged();
        CancelWorkflowCommand.RaiseCanExecuteChanged();
        SkipWorkflowRebootWaitCommand.RaiseCanExecuteChanged();
        StartScanCommand.RaiseCanExecuteChanged();
        CancelScanCommand.RaiseCanExecuteChanged();
        AddSubnetCommand.RaiseCanExecuteChanged();
        SelectAllSubnetsCommand.RaiseCanExecuteChanged();
        DeselectAllSubnetsCommand.RaiseCanExecuteChanged();
        LoadProvisionFromScanCommand.RaiseCanExecuteChanged();
        ProvisionSelectedCommand.RaiseCanExecuteChanged();
        RebootSelectedProvisionCommand.RaiseCanExecuteChanged();
        SelectAllProvisionCommand.RaiseCanExecuteChanged();
        DeselectAllProvisionCommand.RaiseCanExecuteChanged();
        LoadBlanketFromProvisionCommand.RaiseCanExecuteChanged();
        AddBlanketDevicesCommand.RaiseCanExecuteChanged();
        ScanAndLoadBlanketCommand.RaiseCanExecuteChanged();
        LoadBlanketFromScanCommand.RaiseCanExecuteChanged();
        ClearBlanketDevicesCommand.RaiseCanExecuteChanged();
        FetchBlanketCapabilitiesCommand.RaiseCanExecuteChanged();
        ApplyBlanketSettingsCommand.RaiseCanExecuteChanged();
        RebootSelectedBlanketCommand.RaiseCanExecuteChanged();
        SelectAllBlanketCommand.RaiseCanExecuteChanged();
        DeselectAllBlanketCommand.RaiseCanExecuteChanged();
        AddPerDeviceDevicesCommand.RaiseCanExecuteChanged();
        ScanAndLoadPerDeviceCommand.RaiseCanExecuteChanged();
        LoadPerDeviceFromBlanketCommand.RaiseCanExecuteChanged();
        LoadPerDeviceFromProvisionCommand.RaiseCanExecuteChanged();
        FetchPerDeviceStateCommand.RaiseCanExecuteChanged();
        ApplyPerDeviceChangesCommand.RaiseCanExecuteChanged();
        RebootSelectedPerDeviceCommand.RaiseCanExecuteChanged();
        SelectAllPerDeviceCommand.RaiseCanExecuteChanged();
        DeselectAllPerDeviceCommand.RaiseCanExecuteChanged();
        ClearPerDeviceCommand.RaiseCanExecuteChanged();
        SaveSettingsCommand.RaiseCanExecuteChanged();
        ClearSettingsPasswordCommand.RaiseCanExecuteChanged();
        ReloadSettingsCommand.RaiseCanExecuteChanged();
        OpenSettingsFolderCommand.RaiseCanExecuteChanged();
        OpenOutputFolderCommand.RaiseCanExecuteChanged();
    }

    private static string GetAppVersionText()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        if (version is null)
        {
            return "vUnknown";
        }

        var text = $"{version.Major}.{version.Minor}.{version.Build}";
        if (version.Revision > 0)
        {
            text += $".{version.Revision}";
        }

        return $"v{text}";
    }

    private bool SetBlanketOption(ref bool field, bool value)
    {
        if (!SetProperty(ref field, value))
        {
            return false;
        }

        RaiseCommandStates();
        return true;
    }

    private BlanketApplyOptions BuildBlanketOptions()
    {
        return new BlanketApplyOptions
        {
            ApplyNtp = ApplyNtp,
            NtpServer = string.IsNullOrWhiteSpace(NtpServer) ? "time.google.com" : NtpServer.Trim(),
            TimeZoneCode = string.IsNullOrWhiteSpace(TimeZoneCode) ? "010" : TimeZoneCode.Trim(),
            ApplyCloud = ApplyCloud,
            CloudEnabled = CloudEnabled,
            ApplyFusion = ApplyFusion,
            FusionEnabled = FusionEnabled,
            ApplyAutoUpdate = ApplyAutoUpdate,
            AutoUpdateEnabled = AutoUpdateEnabled,
            ApplyDisplay = ApplyDisplay,
            AutoBrightnessEnabled = AutoBrightnessEnabled,
            Brightness = Brightness,
            ScreensaverEnabled = ScreensaverEnabled,
            StandbyTimeout = StandbyTimeout,
            ToolbarEnabled = ToolbarEnabled,
            ApplyAvFramework = ApplyAvFramework,
            AvFrameworkEnabled = AvFrameworkEnabled,
            ApplyInputHdcp = ApplyInputHdcp,
            InputHdcpMode = InputHdcpMode,
            ApplyOutputHdcp = ApplyOutputHdcp,
            OutputHdcpMode = OutputHdcpMode,
            ApplyOutputResolution = ApplyOutputResolution,
            OutputResolution = OutputResolution,
            ApplyGlobalEdid = ApplyGlobalEdid,
            GlobalEdidName = GlobalEdidName.Trim(),
            GlobalEdidType = GlobalEdidType
        };
    }

    private static string ValidateBlanketOptions(BlanketApplyOptions options)
    {
        if (options.ApplyNtp && !Regex.IsMatch(options.TimeZoneCode, @"^\d{3}$"))
        {
            return "Pick a valid time zone.";
        }

        if (options.ApplyDisplay)
        {
            if (!options.AutoBrightnessEnabled && options.Brightness is < 0 or > 100)
            {
                return "Brightness must be between 0 and 100.";
            }

            if (options.StandbyTimeout is < 0 or > 86400)
            {
                return "Standby timeout must be between 0 and 86400.";
            }
        }

        if (options.ApplyGlobalEdid && string.IsNullOrWhiteSpace(options.GlobalEdidName))
        {
            return "Enter or select a Global EDID name.";
        }

        return "";
    }

    private void RefreshGlobalEdidNameOptions()
    {
        var names = BlanketRows
            .SelectMany(row => (row.EdidNames ?? "")
                .Split(['|', ';', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        GlobalEdidNameOptions.Clear();
        foreach (var name in names)
        {
            GlobalEdidNameOptions.Add(name);
        }

        if (string.IsNullOrWhiteSpace(GlobalEdidName) && GlobalEdidNameOptions.Count > 0)
        {
            GlobalEdidName = GlobalEdidNameOptions[0];
        }
    }

    private static string NormalizeProvisionStatus(string status, string success)
    {
        if (string.Equals(success, "True", StringComparison.OrdinalIgnoreCase))
        {
            return "OK";
        }

        if (int.TryParse(status, out var httpStatus))
        {
            return httpStatus.ToString();
        }

        return string.IsNullOrWhiteSpace(status) ? "Failed" : status;
    }

    private static bool IsValidCidr(string value)
    {
        if (!CidrPattern.IsMatch(value))
        {
            return false;
        }

        var parts = value.Split('/');
        var prefix = int.Parse(parts[1]);
        if (prefix is < 0 or > 32)
        {
            return false;
        }

        return parts[0]
            .Split('.')
            .Select(part => int.TryParse(part, out var octet) ? octet : -1)
            .All(octet => octet is >= 0 and <= 255);
    }

    private static string[] ParseIpList(string value, out string[] invalid)
    {
        var bad = new List<string>();
        var good = new List<string>();
        var parts = value.Split([',', ';', '\r', '\n', '\t', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        foreach (var part in parts)
        {
            if (!IPAddress.TryParse(part, out var address))
            {
                bad.Add(part);
                continue;
            }

            good.Add(address.ToString());
        }

        invalid = bad.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return good.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private sealed class GuiSettingsFile
    {
        public string DefaultUsername { get; set; } = "";
        public string ProtectedDefaultPassword { get; set; } = "";
        public bool DarkMode { get; set; } = true;
        public List<string> MostUsedSubnets { get; set; } = new();
    }
}

public sealed record TimeZoneOption(string Code, string Name)
{
    public override string ToString() => Name;
}
