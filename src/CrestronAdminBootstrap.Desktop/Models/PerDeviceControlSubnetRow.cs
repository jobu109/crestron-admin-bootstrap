using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceControlSubnetRow : ObservableObject
{
    private string _newEnabled = "N/A";
    private string _ipMode = "N/A";
    private string _newIPAddress = "N/A";
    private string _newSubnetMask = "N/A";
    private string _newGateway = "N/A";
    private string _newIgmpVersion = "N/A";
    private string _newRouterAutomaticMode = "N/A";
    private string _newRouterPrefix = "N/A";
    private string _newRouterOnlineDelay = "N/A";
    private string _newRouterIsolationMode = "N/A";
    private string _newIgmpProxy = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public bool SupportsControlSubnet { get; init; }
    public bool SupportsRouter { get; init; }
    public bool SupportsIgmpProxy { get; init; }
    public string CurrentEnabled { get; init; } = "N/A";
    public bool? CurrentDhcp { get; init; }
    public string CurrentIPAddress { get; init; } = "N/A";
    public string CurrentSubnetMask { get; init; } = "N/A";
    public string CurrentGateway { get; init; } = "N/A";
    public string CurrentIgmpVersion { get; init; } = "N/A";
    public string CurrentRouterAutomaticMode { get; init; } = "N/A";
    public string CurrentRouterPrefix { get; init; } = "N/A";
    public string CurrentRouterOnlineDelay { get; init; } = "N/A";
    public string CurrentRouterIsolationMode { get; init; } = "N/A";
    public string CurrentIgmpProxy { get; init; } = "N/A";
    public string IgmpProxyPropertyName { get; init; } = "";

    public string NewEnabled
    {
        get => _newEnabled;
        set => SetProperty(ref _newEnabled, value);
    }

    public string IPMode
    {
        get => _ipMode;
        set => SetProperty(ref _ipMode, value);
    }

    public string NewIPAddress
    {
        get => _newIPAddress;
        set => SetProperty(ref _newIPAddress, value);
    }

    public string NewSubnetMask
    {
        get => _newSubnetMask;
        set => SetProperty(ref _newSubnetMask, value);
    }

    public string NewGateway
    {
        get => _newGateway;
        set => SetProperty(ref _newGateway, value);
    }

    public string NewIgmpVersion
    {
        get => _newIgmpVersion;
        set => SetProperty(ref _newIgmpVersion, value);
    }

    public string NewRouterAutomaticMode
    {
        get => _newRouterAutomaticMode;
        set => SetProperty(ref _newRouterAutomaticMode, value);
    }

    public string NewRouterPrefix
    {
        get => _newRouterPrefix;
        set => SetProperty(ref _newRouterPrefix, value);
    }

    public string NewRouterOnlineDelay
    {
        get => _newRouterOnlineDelay;
        set => SetProperty(ref _newRouterOnlineDelay, value);
    }

    public string NewRouterIsolationMode
    {
        get => _newRouterIsolationMode;
        set => SetProperty(ref _newRouterIsolationMode, value);
    }

    public string NewIgmpProxy
    {
        get => _newIgmpProxy;
        set => SetProperty(ref _newIgmpProxy, value);
    }

    public bool HasChanges =>
        SupportsControlSubnet &&
        (ToggleChanged(NewEnabled, CurrentEnabled) ||
         ModeChanged() ||
         Changed(NewIPAddress, CurrentIPAddress) ||
         Changed(NewSubnetMask, CurrentSubnetMask) ||
         Changed(NewGateway, CurrentGateway) ||
         ChoiceChanged(NewIgmpVersion, CurrentIgmpVersion, "V2", "V3") ||
         (SupportsRouter && ToggleChanged(NewRouterAutomaticMode, CurrentRouterAutomaticMode)) ||
         (SupportsRouter && Changed(NewRouterPrefix, CurrentRouterPrefix)) ||
         (SupportsRouter && Changed(NewRouterOnlineDelay, CurrentRouterOnlineDelay)) ||
         (SupportsRouter && ToggleChanged(NewRouterIsolationMode, CurrentRouterIsolationMode)) ||
         (SupportsIgmpProxy && ToggleChanged(NewIgmpProxy, CurrentIgmpProxy)));

    private bool ModeChanged()
    {
        if (IPMode is not ("DHCP" or "Static"))
        {
            return false;
        }

        return !string.Equals(IPMode, CurrentMode(), StringComparison.OrdinalIgnoreCase);
    }

    private string CurrentMode()
    {
        if (CurrentDhcp is null)
        {
            return "N/A";
        }

        return CurrentDhcp.Value ? "DHCP" : "Static";
    }

    private static bool ToggleChanged(string newValue, string currentValue)
    {
        return ChoiceChanged(newValue, currentValue, "Enabled", "Disabled");
    }

    private static bool ChoiceChanged(string newValue, string currentValue, params string[] allowedValues)
    {
        if (!allowedValues.Any(value => string.Equals(value, newValue, StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
