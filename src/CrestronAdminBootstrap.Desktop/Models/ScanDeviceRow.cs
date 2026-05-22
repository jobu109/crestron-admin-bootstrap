namespace CrestronAdminBootstrap.Desktop.Models;

public sealed class ScanDeviceRow
{
    public bool Selected { get; set; } = true;
    public string IP { get; set; } = "";
    public string MatchedSig { get; set; } = "";
    public string ScannedAt { get; set; } = "";
}
