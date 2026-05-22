using System.Collections.ObjectModel;
using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceAvOutputRow : ObservableObject
{
    private string _newOutputHdcp = "N/A";
    private string _newOutputResolution = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public int OutputIndex { get; init; }
    public string OutputLabel { get; init; } = "";
    public string CurrentOutputHdcp { get; init; } = "N/A";
    public string CurrentOutputResolution { get; init; } = "N/A";
    public bool SupportsAvSettings { get; init; }
    public ObservableCollection<string> OutputResolutionOptions { get; } = new();

    public string NewOutputHdcp
    {
        get => _newOutputHdcp;
        set => SetProperty(ref _newOutputHdcp, value);
    }

    public string NewOutputResolution
    {
        get => _newOutputResolution;
        set => SetProperty(ref _newOutputResolution, value);
    }

    public bool HasChanges =>
        Changed(NewOutputHdcp, CurrentOutputHdcp) ||
        Changed(NewOutputResolution, CurrentOutputResolution);

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
