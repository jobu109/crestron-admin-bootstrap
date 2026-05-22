using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class ProvisionDeviceRow : ObservableObject
{
    private bool _selected = true;
    private string _status = "Pending";
    private string _success = "";
    private string _response = "";
    private string _timestamp = "";

    public string IP { get; init; } = "";

    public bool Selected
    {
        get => _selected;
        set => SetProperty(ref _selected, value);
    }

    public string Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public string Success
    {
        get => _success;
        set => SetProperty(ref _success, value);
    }

    public string Response
    {
        get => _response;
        set => SetProperty(ref _response, value);
    }

    public string Timestamp
    {
        get => _timestamp;
        set => SetProperty(ref _timestamp, value);
    }
}
