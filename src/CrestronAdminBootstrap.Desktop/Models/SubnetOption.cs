using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class SubnetOption : ObservableObject
{
    private bool _isSelected;

    public SubnetOption(string cidr, bool isSelected = true)
    {
        Cidr = cidr;
        _isSelected = isSelected;
    }

    public string Cidr { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }
}
