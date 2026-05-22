using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace CrestronAdminBootstrap.Desktop;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

        base.OnStartup(e);

        try
        {
            MainWindow = new MainWindow();
            MainWindow.Show();
        }
        catch (Exception ex)
        {
            ReportException("Crestron Admin Bootstrap failed to start", ex);
            Shutdown(1);
        }
    }

    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        ReportException("Unexpected error", e.Exception);
        e.Handled = true;
    }

    private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception ex)
        {
            ReportException("Fatal error", ex);
        }
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        ReportException("Background task error", e.Exception);
        e.SetObserved();
    }

    private static void ReportException(string title, Exception exception)
    {
        var logPath = WriteExceptionLog(title, exception);
        var message = new StringBuilder()
            .AppendLine(exception.Message)
            .AppendLine()
            .AppendLine("A diagnostic log was written to:")
            .AppendLine(logPath)
            .ToString();

        try
        {
            MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Error);
        }
        catch
        {
            // If WPF is too injured to show a dialog, the log is still the useful artifact.
        }
    }

    private static string WriteExceptionLog(string title, Exception exception)
    {
        var preferredPath = Path.Combine(AppContext.BaseDirectory, "CrestronBootstrap-error.log");
        var fallbackPath = Path.Combine(Path.GetTempPath(), "CrestronBootstrap-error.log");
        var entry = new StringBuilder()
            .AppendLine("==== Crestron Admin Bootstrap Error ====")
            .AppendLine($"Time: {DateTimeOffset.Now:o}")
            .AppendLine($"Title: {title}")
            .AppendLine(exception.ToString())
            .AppendLine()
            .ToString();

        try
        {
            File.AppendAllText(preferredPath, entry);
            return preferredPath;
        }
        catch
        {
            File.AppendAllText(fallbackPath, entry);
            return fallbackPath;
        }
    }
}
