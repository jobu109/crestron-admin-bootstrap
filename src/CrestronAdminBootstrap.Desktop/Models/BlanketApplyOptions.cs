namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class BlanketApplyOptions
{
    public bool ApplyNtp { get; set; }
    public string NtpServer { get; set; } = "time.google.com";
    public string TimeZoneCode { get; set; } = "010";

    public bool ApplyCloud { get; set; }
    public bool CloudEnabled { get; set; } = true;

    public bool ApplyFusion { get; set; }
    public bool FusionEnabled { get; set; } = true;

    public bool ApplyAutoUpdate { get; set; }
    public bool AutoUpdateEnabled { get; set; } = true;

    public bool ApplyDisplay { get; set; }
    public bool AutoBrightnessEnabled { get; set; } = true;
    public int Brightness { get; set; } = 80;
    public bool ScreensaverEnabled { get; set; } = true;
    public int StandbyTimeout { get; set; } = 10;
    public bool ToolbarEnabled { get; set; } = true;

    public bool ApplyAvFramework { get; set; }
    public bool AvFrameworkEnabled { get; set; } = true;

    public bool ApplyInputHdcp { get; set; }
    public string InputHdcpMode { get; set; } = "Auto";

    public bool ApplyOutputHdcp { get; set; }
    public string OutputHdcpMode { get; set; } = "Auto";

    public bool ApplyOutputResolution { get; set; }
    public string OutputResolution { get; set; } = "Auto";

    public bool ApplyGlobalEdid { get; set; }
    public string GlobalEdidName { get; set; } = "";
    public string GlobalEdidType { get; set; } = "System";

    public bool HasAnySelection =>
        ApplyNtp ||
        ApplyCloud ||
        ApplyFusion ||
        ApplyAutoUpdate ||
        ApplyDisplay ||
        ApplyAvFramework ||
        ApplyInputHdcp ||
        ApplyOutputHdcp ||
        ApplyOutputResolution ||
        ApplyGlobalEdid;
}
