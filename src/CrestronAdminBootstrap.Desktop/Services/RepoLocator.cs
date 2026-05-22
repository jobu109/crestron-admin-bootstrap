using System.IO;

namespace CrestronAdminBootstrap.Desktop.Services;

public static class RepoLocator
{
    public static string FindRepoRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var manifest = Path.Combine(
                current.FullName,
                "src",
                "CrestronAdminBootstrap",
                "CrestronAdminBootstrap.psd1");

            if (File.Exists(manifest))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return Directory.GetCurrentDirectory();
    }

    public static string FindSettingsPath(string repoRoot)
    {
        var dataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CrestronAdminBootstrap");
        Directory.CreateDirectory(dataRoot);

        var appDataSettings = Path.Combine(dataRoot, "gui-settings.json");
        var legacySettings = Path.Combine(repoRoot, "gui-settings.json");

        if (!File.Exists(appDataSettings) && File.Exists(legacySettings))
        {
            try
            {
                File.Copy(legacySettings, appDataSettings);
            }
            catch
            {
                return legacySettings;
            }
        }

        return appDataSettings;
    }
}
