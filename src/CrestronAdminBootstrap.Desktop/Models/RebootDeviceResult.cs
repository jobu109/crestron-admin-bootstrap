namespace CrestronAdminBootstrap.Desktop.Models;

public sealed record RebootDeviceResult(
    string IP,
    string Status,
    bool Success,
    string Response,
    string Timestamp);
