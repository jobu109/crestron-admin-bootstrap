using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceAvDeviceRow : ObservableObject
{
    private string _newAutoInputRouting = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public bool SupportsAvRouting { get; init; }
    public string CurrentAutoInputRouting { get; init; } = "N/A";

    public string NewAutoInputRouting
    {
        get => _newAutoInputRouting;
        set => SetProperty(ref _newAutoInputRouting, value);
    }

    public bool HasChanges => Changed(NewAutoInputRouting, CurrentAutoInputRouting);

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
