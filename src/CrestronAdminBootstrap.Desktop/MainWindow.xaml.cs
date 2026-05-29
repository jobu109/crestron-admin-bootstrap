using System.Windows;
using System.ComponentModel;
using System.Windows.Media;
using CrestronAdminBootstrap.Desktop.Services;
using CrestronAdminBootstrap.Desktop.ViewModels;

namespace CrestronAdminBootstrap.Desktop;

public partial class MainWindow : Window
{
    private bool _syncingSettingsPassword;
    private bool _syncingSettingsConfirmPassword;

    public MainWindow()
    {
        InitializeComponent();

        var viewModel = new MainViewModel(new PowerShellBackend());
        DataContext = viewModel;
        ApplyTheme(viewModel.SettingsDarkMode);

        SettingsDefaultPasswordBox.PasswordChanged += (_, _) =>
        {
            if (_syncingSettingsPassword) return;
            viewModel.SettingsDefaultPassword = SettingsDefaultPasswordBox.Password;
        };

        SettingsConfirmPasswordBox.PasswordChanged += (_, _) =>
        {
            if (_syncingSettingsConfirmPassword) return;
            viewModel.SettingsConfirmPassword = SettingsConfirmPasswordBox.Password;
        };

        viewModel.PropertyChanged += OnViewModelPropertyChanged;
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.SettingsDarkMode) &&
            sender is MainViewModel themeViewModel)
        {
            ApplyTheme(themeViewModel.SettingsDarkMode);
            return;
        }

        if (sender is not MainViewModel viewModel) return;

        if (e.PropertyName == nameof(MainViewModel.SettingsDefaultPassword) &&
            SettingsDefaultPasswordBox.Password != viewModel.SettingsDefaultPassword)
        {
            _syncingSettingsPassword = true;
            try { SettingsDefaultPasswordBox.Password = viewModel.SettingsDefaultPassword; }
            finally { _syncingSettingsPassword = false; }
        }

        if (e.PropertyName == nameof(MainViewModel.SettingsConfirmPassword) &&
            SettingsConfirmPasswordBox.Password != viewModel.SettingsConfirmPassword)
        {
            _syncingSettingsConfirmPassword = true;
            try { SettingsConfirmPasswordBox.Password = viewModel.SettingsConfirmPassword; }
            finally { _syncingSettingsConfirmPassword = false; }
        }
    }

    private void ApplyTheme(bool darkMode)
    {
        var colors = darkMode
            ? new Dictionary<string, string>
            {
                ["AppBackgroundBrush"] = "#202124",
                ["PanelBrush"] = "#2B2D31",
                ["PanelAltBrush"] = "#32353B",
                ["BorderBrushDark"] = "#50545C",
                ["TextBrush"] = "#F3F5F7",
                ["MutedTextBrush"] = "#AEB4BE",
                ["AccentBrush"] = "#2D7DD2",
                ["AccentBrushHover"] = "#3D8EE4",
                ["InputBrush"] = "#1E1F22",
                ["InputBorderBrush"] = "#616671",
                ["GridHeaderBrush"] = "#363941",
                ["GridRowBrush"] = "#2B2D31",
                ["GridAltRowBrush"] = "#26282D",
                ["GridSelectedBrush"] = "#245B94"
            }
            : new Dictionary<string, string>
            {
                ["AppBackgroundBrush"] = "#F4F6F8",
                ["PanelBrush"] = "#FFFFFF",
                ["PanelAltBrush"] = "#EEF1F5",
                ["BorderBrushDark"] = "#B8C0CC",
                ["TextBrush"] = "#111827",
                ["MutedTextBrush"] = "#526070",
                ["AccentBrush"] = "#1F6DB5",
                ["AccentBrushHover"] = "#2D7DD2",
                ["InputBrush"] = "#FFFFFF",
                ["InputBorderBrush"] = "#8792A2",
                ["GridHeaderBrush"] = "#E7EBF1",
                ["GridRowBrush"] = "#FFFFFF",
                ["GridAltRowBrush"] = "#F5F7FA",
                ["GridSelectedBrush"] = "#D6E8FA"
            };

        foreach (var (key, value) in colors)
        {
            Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
        }

        Resources[SystemColors.WindowBrushKey] = Resources["InputBrush"];
        Resources[SystemColors.ControlBrushKey] = Resources["PanelAltBrush"];
        Resources[SystemColors.ControlTextBrushKey] = Resources["TextBrush"];
        Resources[SystemColors.HighlightBrushKey] = Resources["AccentBrush"];
        Resources[SystemColors.HighlightTextBrushKey] = Resources["TextBrush"];
        Resources[SystemColors.GrayTextBrushKey] = Resources["MutedTextBrush"];

        Background = (Brush)Resources["AppBackgroundBrush"];
    }
}
