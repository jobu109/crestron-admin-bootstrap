using System.Collections.ObjectModel;
using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class PerDeviceAvInputRow : ObservableObject
{
    private string _newEdidName = "";
    private string _newInputHdcp = "N/A";
    private string _newAutoInputRouting = "N/A";

    public string IP { get; init; } = "";
    public string Model { get; init; } = "";
    public string Hostname { get; init; } = "";
    public int InputIndex { get; init; }
    public string InputLabel { get; init; } = "";
    public string PortType { get; init; } = "";
    public string CurrentEdid { get; init; } = "";
    public string CurrentInputHdcp { get; init; } = "N/A";
    public bool SupportsAvSettings { get; init; }
    public bool SupportsEdidEdit { get; init; }
    public bool SupportsAvRouting { get; init; }
    public string CurrentAutoInputRouting { get; init; } = "N/A";
    public ObservableCollection<string> EdidNameOptions { get; } = new();

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

    public string NewAutoInputRouting
    {
        get => _newAutoInputRouting;
        set => SetProperty(ref _newAutoInputRouting, value);
    }

    public bool HasChanges =>
        Changed(NewEdidName, CurrentEdid) ||
        Changed(NewInputHdcp, CurrentInputHdcp) ||
        Changed(NewAutoInputRouting, CurrentAutoInputRouting);

    private static bool Changed(string newValue, string currentValue)
    {
        if (string.IsNullOrWhiteSpace(newValue) || string.Equals(newValue, "N/A", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return !string.Equals(newValue.Trim(), (currentValue ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
}
