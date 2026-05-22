using System.Collections.ObjectModel;
using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceMulticastRow : ObservableObject
{
    private string _deviceMode = "N/A";
    private string _newMulticastAddress = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public string Direction { get; init; } = "";
    public string CurrentDeviceMode { get; init; } = "N/A";
    public bool SupportsModeChange { get; init; }
    public int StreamIndex { get; init; }
    public string CurrentMulticastAddress { get; init; } = "N/A";
    public bool SupportsAvMulticast { get; init; }
    public ObservableCollection<string> DeviceModeOptions { get; } = new();

    public string DeviceMode
    {
        get => _deviceMode;
        set => SetProperty(ref _deviceMode, value);
    }

    public string NewMulticastAddress
    {
        get => _newMulticastAddress;
        set => SetProperty(ref _newMulticastAddress, value);
    }

    public bool HasChanges =>
        SupportsAvMulticast &&
        ((DeviceMode is "Transmitter" or "Receiver" &&
          !string.Equals(DeviceMode, CurrentDeviceMode, StringComparison.OrdinalIgnoreCase)) ||
         Changed(NewMulticastAddress, CurrentMulticastAddress));

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
