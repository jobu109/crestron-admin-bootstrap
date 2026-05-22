using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class BlanketDeviceRow : ObservableObject
{
    private bool _selected = true;
    private string _model = "";
    private string _hostname = "";
    private string _currentDeviceMode = "";
    private string _avApiFamily = "";
    private string _avApiVersion = "";
    private bool _supportsAvSettings;
    private bool _supportsGlobalEdid;
    private string _edidNames = "";
    private bool _supportsNtp;
    private bool _supportsCloud;
    private bool _supportsFusion;
    private bool _supportsAutoUpdate;
    private bool _supportsDisplaySettings;
    private bool _supportsToolbarSettings;
    private bool _supportsAvFrameworkSettings;
    private bool _capabilitiesFetched;
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

    public string Hostname
    {
        get => _hostname;
        set => SetProperty(ref _hostname, value);
    }

    public string CurrentDeviceMode
    {
        get => _currentDeviceMode;
        set => SetProperty(ref _currentDeviceMode, value);
    }

    public string AvApiFamily
    {
        get => _avApiFamily;
        set => SetProperty(ref _avApiFamily, value);
    }

    public string AvApiVersion
    {
        get => _avApiVersion;
        set => SetProperty(ref _avApiVersion, value);
    }

    public bool SupportsAvSettings
    {
        get => _supportsAvSettings;
        set => SetProperty(ref _supportsAvSettings, value);
    }

    public bool SupportsGlobalEdid
    {
        get => _supportsGlobalEdid;
        set => SetProperty(ref _supportsGlobalEdid, value);
    }

    public string EdidNames
    {
        get => _edidNames;
        set => SetProperty(ref _edidNames, value);
    }

    public bool SupportsNtp
    {
        get => _supportsNtp;
        set => SetProperty(ref _supportsNtp, value);
    }

    public bool SupportsCloud
    {
        get => _supportsCloud;
        set => SetProperty(ref _supportsCloud, value);
    }

    public bool SupportsFusion
    {
        get => _supportsFusion;
        set => SetProperty(ref _supportsFusion, value);
    }

    public bool SupportsAutoUpdate
    {
        get => _supportsAutoUpdate;
        set => SetProperty(ref _supportsAutoUpdate, value);
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

    public bool CapabilitiesFetched
    {
        get => _capabilitiesFetched;
        set => SetProperty(ref _capabilitiesFetched, value);
    }

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public string Detail
    {
        get => _detail;
        set => SetProperty(ref _detail, value);
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
}
