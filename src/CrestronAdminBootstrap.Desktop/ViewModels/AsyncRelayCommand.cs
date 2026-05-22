using System.Windows.Input;

namespace CrestronAdminBootstrap.Desktop.ViewModels;

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<CancellationToken, Task> _executeAsync;
    private readonly Func<bool>? _canExecute;
    private bool _isRunning;

    public AsyncRelayCommand(Func<CancellationToken, Task> executeAsync, Func<bool>? canExecute = null)
    {
        _executeAsync = executeAsync;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool IsRunning
    {
        get => _isRunning;
        private set
        {
            if (_isRunning == value)
            {
                return;
            }

            _isRunning = value;
            RaiseCanExecuteChanged();
        }
    }

    public bool CanExecute(object? parameter)
    {
        return !IsRunning && (_canExecute?.Invoke() ?? true);
    }

    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter))
        {
            return;
        }

        IsRunning = true;
        try
        {
            await _executeAsync(CancellationToken.None).ConfigureAwait(true);
        }
        finally
        {
            IsRunning = false;
        }
    }

    public void RaiseCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
