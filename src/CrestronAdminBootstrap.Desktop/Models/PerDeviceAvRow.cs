using System.Collections.ObjectModel;
using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceAvRow : ObservableObject
{
    private string _newEdidName = "";
    private string _newInputHdcp = "N/A";
    private string _newOutputHdcp = "N/A";
    private string _newOutputResolution = "N/A";
    private string _newAutoInputRouting = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public string RowKind { get; init; } = "";   // "Input" | "Output" | "Device"
    public string PortLabel { get; init; } = "";
    public string PortType { get; init; } = "";
    public int InputIndex { get; init; } = -1;
    public int OutputIndex { get; init; } = -1;

    // Input
    public bool SupportsEdidEdit { get; init; }
    public bool SupportsInputHdcp { get; init; }
    public ObservableCollection<string> EdidNameOptions { get; } = new();
    public string CurrentEdid { get; init; } = "N/A";
    public string CurrentInputHdcp { get; init; } = "N/A";

    // Output
    public bool SupportsOutputHdcp { get; init; }
    public bool SupportsOutputResolution { get; init; }
    public ObservableCollection<string> OutputResolutionOptions { get; } = new();
    public string CurrentOutputHdcp { get; init; } = "N/A";
    public string CurrentOutputResolution { get; init; } = "N/A";

    // Device-level
    public bool SupportsAvRouting { get; init; }
    public string CurrentAutoInputRouting { get; init; } = "N/A";

    public string NewEdidName
    {
        get => _newEdidName;
        set => SetProperty(ref _newEdidName, value);
    }

    public string NewInputHdcp
    {
        get => _newInputHdcp;
        set => SetProperty(ref _newInputHdcp, value);
    }

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

    public string NewAutoInputRouting
    {
        get => _newAutoInputRouting;
        set => SetProperty(ref _newAutoInputRouting, value);
    }

    public bool HasChanges =>
        Changed(NewEdidName, CurrentEdid) ||
        Changed(NewInputHdcp, CurrentInputHdcp) ||
        Changed(NewOutputHdcp, CurrentOutputHdcp) ||
        Changed(NewOutputResolution, CurrentOutputResolution) ||
        Changed(NewAutoInputRouting, CurrentAutoInputRouting);

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
            return false;
        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
