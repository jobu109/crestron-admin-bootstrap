using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class WorkflowStepRow : ObservableObject
{
    private string _state = "Pending";
    private string _detail = "";

    public int Number { get; init; }
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";

    public string State
    {
        get => _state;
        set => SetProperty(ref _state, value);
    }

    public string Detail
    {
        get => _detail;
        set => SetProperty(ref _detail, value);
    }
}
