using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceDeviceRow : ObservableObject
{
    private bool _selected = true;
    private string _model = "";
    private string _firmware = "";
    private string _currentHostname = "";
    private string _newHostname = "N/A";
    private bool _supportsNetwork;
    private bool _supportsIpTable;
    private bool _hasWifi;
    private bool _supportsDisplaySettings;
    private bool _supportsToolbarSettings;
    private bool _supportsAvFrameworkSettings;
    private string _ipMode = "N/A";
    private string _currentIP = "";
    private string _newIP = "N/A";
    private string _currentSubnet = "";
    private string _subnetMask = "N/A";
    private string _currentGateway = "";
    private string _gateway = "N/A";
    private string _currentDns1 = "";
    private string _primaryDns = "N/A";
    private string _currentDns2 = "";
    private string _secondaryDns = "";
    private bool _disableWifi;
    private string _currentAutoBrightness = "N/A";
    private string _newAutoBrightness = "N/A";
    private string _currentBrightness = "N/A";
    private string _newBrightness = "N/A";
    private string _currentScreensaver = "N/A";
    private string _newScreensaver = "N/A";
    private string _currentStandbyTimeout = "N/A";
    private string _newStandbyTimeout = "N/A";
    private string _currentToolbar = "N/A";
    private string _newToolbar = "N/A";
    private string _currentAvFramework = "N/A";
    private string _newAvFramework = "N/A";
    private string _currentIpId = "";
    private string _newIpId = "N/A";
    private string _currentControlSystemAddr = "";
    private string _newControlSystemAddr = "N/A";
    private string _status = "Pending";
    private string _detail = "";
    private bool _needsReboot;
    private string _timestamp = "";

    public string IP { get; init; } = "";

    public bool Selected
    {
        get => _selected;
        set => SetProperty(ref _selected, value);
    }

    public string Model
    {
        get => _model;
        set => SetProperty(ref _model, value);
    }

    public string Firmware
    {
        get => _firmware;
        set => SetProperty(ref _firmware, value);
    }

    public string CurrentHostname
    {
        get => _currentHostname;
        set => SetProperty(ref _currentHostname, value);
    }

    public string NewHostname
    {
        get => _newHostname;
        set => SetProperty(ref _newHostname, value);
    }

    public bool SupportsNetwork
    {
        get => _supportsNetwork;
        set => SetProperty(ref _supportsNetwork, value);
    }

    public bool SupportsIpTable
    {
        get => _supportsIpTable;
        set => SetProperty(ref _supportsIpTable, value);
    }

    public bool HasWifi
    {
        get => _hasWifi;
        set => SetProperty(ref _hasWifi, value);
    }

    public bool SupportsDisplaySettings
    {
        get => _supportsDisplaySettings;
        set => SetProperty(ref _supportsDisplaySettings, value);
    }

    public bool SupportsToolbarSettings
    {
        get => _supportsToolbarSettings;
        set => SetProperty(ref _supportsToolbarSettings, value);
    }

    public bool SupportsAvFrameworkSettings
    {
        get => _supportsAvFrameworkSettings;
        set => SetProperty(ref _supportsAvFrameworkSettings, value);
    }

    public string CurrentIPMode { get; init; } = "N/A";

    public string IPMode
    {
        get => _ipMode;
        set => SetProperty(ref _ipMode, value);
    }

    public string CurrentIP
    {
        get => _currentIP;
        set => SetProperty(ref _currentIP, value);
    }

    public string NewIP
    {
        get => _newIP;
        set => SetProperty(ref _newIP, value);
    }

    public string CurrentSubnet
    {
        get => _currentSubnet;
        set => SetProperty(ref _currentSubnet, value);
    }

    public string SubnetMask
    {
        get => _subnetMask;
        set => SetProperty(ref _subnetMask, value);
    }

    public string CurrentGateway
    {
        get => _currentGateway;
        set => SetProperty(ref _currentGateway, value);
    }

    public string Gateway
    {
        get => _gateway;
        set => SetProperty(ref _gateway, value);
    }

    public string CurrentDns1
    {
        get => _currentDns1;
        set => SetProperty(ref _currentDns1, value);
    }

    public string PrimaryDns
    {
        get => _primaryDns;
        set => SetProperty(ref _primaryDns, value);
    }

    public string CurrentDns2
    {
        get => _currentDns2;
        set => SetProperty(ref _currentDns2, value);
    }

    public string SecondaryDns
    {
        get => _secondaryDns;
        set => SetProperty(ref _secondaryDns, value);
    }

    public bool DisableWifi
    {
        get => _disableWifi;
        set => SetProperty(ref _disableWifi, value);
    }

    public string CurrentAutoBrightness
    {
        get => _currentAutoBrightness;
        set => SetProperty(ref _currentAutoBrightness, value);
    }

    public string NewAutoBrightness
    {
        get => _newAutoBrightness;
        set => SetProperty(ref _newAutoBrightness, value);
    }

    public string CurrentBrightness
    {
        get => _currentBrightness;
        set => SetProperty(ref _currentBrightness, value);
    }

    public string NewBrightness
    {
        get => _newBrightness;
        set => SetProperty(ref _newBrightness, value);
    }

    public string CurrentScreensaver
    {
        get => _currentScreensaver;
        set => SetProperty(ref _currentScreensaver, value);
    }

    public string NewScreensaver
    {
        get => _newScreensaver;
        set => SetProperty(ref _newScreensaver, value);
    }

    public string CurrentStandbyTimeout
    {
        get => _currentStandbyTimeout;
        set => SetProperty(ref _currentStandbyTimeout, value);
    }

    public string NewStandbyTimeout
    {
        get => _newStandbyTimeout;
        set => SetProperty(ref _newStandbyTimeout, value);
    }

    public string CurrentToolbar
    {
        get => _currentToolbar;
        set => SetProperty(ref _currentToolbar, value);
    }

    public string NewToolbar
    {
        get => _newToolbar;
        set => SetProperty(ref _newToolbar, value);
    }

    public string CurrentAvFramework
    {
        get => _currentAvFramework;
        set => SetProperty(ref _currentAvFramework, value);
    }

    public string NewAvFramework
    {
        get => _newAvFramework;
        set => SetProperty(ref _newAvFramework, value);
    }

    public string CurrentIpId
    {
        get => _currentIpId;
        set => SetProperty(ref _currentIpId, value);
    }

    public string NewIpId
    {
        get => _newIpId;
        set => SetProperty(ref _newIpId, value);
    }

    public string CurrentControlSystemAddr
    {
        get => _currentControlSystemAddr;
        set => SetProperty(ref _currentControlSystemAddr, value);
    }

    public string NewControlSystemAddr
    {
        get => _newControlSystemAddr;
        set => SetProperty(ref _newControlSystemAddr, value);
    }

    public string Status
    {
        get => _status;
        set
        {
            if (SetProperty(ref _status, value))
            {
                OnPropertyChanged(nameof(ApplySummary));
                OnPropertyChanged(nameof(DisplayStatus));
            }
        }
    }

    public string Detail
    {
        get => _detail;
        set
        {
            if (SetProperty(ref _detail, value))
            {
                OnPropertyChanged(nameof(ApplySummary));
                OnPropertyChanged(nameof(DisplayStatus));
            }
        }
    }

    public string ApplySummary
    {
        get
        {
            if (string.IsNullOrWhiteSpace(Status) ||
                string.Equals(Status, "Pending", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(Status, "Working", StringComparison.OrdinalIgnoreCase))
                return "";
            if (string.IsNullOrWhiteSpace(Detail)) return Status;
            if (Detail.StartsWith("ERROR:", StringComparison.OrdinalIgnoreCase)) return "Error";
            if (string.Equals(Detail, "OK", StringComparison.OrdinalIgnoreCase)) return "Fetched";
            var parts = Detail.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var ok = parts.Count(p => p.EndsWith("=OK", StringComparison.OrdinalIgnoreCase));
            var skipped = parts.Count(p => p.Contains("skipped", StringComparison.OrdinalIgnoreCase));
            var summary = new List<string>();
            if (ok > 0) summary.Add($"{ok} accepted");
            if (skipped > 0) summary.Add($"{skipped} skipped");
            return summary.Count > 0 ? string.Join(", ", summary) : Status;
        }
    }

    public string DisplayStatus
    {
        get
        {
            if (!string.Equals(Status, "Failed", StringComparison.OrdinalIgnoreCase))
                return Status;
            var hasSkipped = !string.IsNullOrWhiteSpace(Detail) &&
                             Detail.Contains("skipped", StringComparison.OrdinalIgnoreCase);
            return hasSkipped ? "OK, with skips" : "Partial";
        }
    }

    public bool NeedsReboot
    {
        get => _needsReboot;
        set => SetProperty(ref _needsReboot, value);
    }

    public string Timestamp
    {
        get => _timestamp;
        set => SetProperty(ref _timestamp, value);
    }

    public bool HasChanges =>
        Changed(NewHostname, CurrentHostname) ||
        Changed(NewIP, CurrentIP) ||
        Changed(SubnetMask, CurrentSubnet) ||
        Changed(Gateway, CurrentGateway) ||
        Changed(PrimaryDns, CurrentDns1) ||
        Changed(SecondaryDns, CurrentDns2) ||
        (!string.Equals(IPMode, "N/A", StringComparison.OrdinalIgnoreCase) &&
         !string.Equals(IPMode, CurrentIPMode, StringComparison.OrdinalIgnoreCase)) ||
        (HasWifi && DisableWifi) ||
        Changed(NewAutoBrightness, CurrentAutoBrightness) ||
        Changed(NewBrightness, CurrentBrightness) ||
        Changed(NewScreensaver, CurrentScreensaver) ||
        Changed(NewStandbyTimeout, CurrentStandbyTimeout) ||
        Changed(NewToolbar, CurrentToolbar) ||
        Changed(NewAvFramework, CurrentAvFramework) ||
        Changed(NewIpId, CurrentIpId) ||
        Changed(NewControlSystemAddr, CurrentControlSystemAddr);

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
