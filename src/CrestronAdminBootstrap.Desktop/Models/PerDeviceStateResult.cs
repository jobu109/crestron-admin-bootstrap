namespace CrestronAdminBootstrap.Desktop.Models;

public sealed record PerDeviceStateResult(
    IReadOnlyList<PerDeviceDeviceRow> DeviceRows,
    IReadOnlyList<PerDeviceAvRow> AvRows,
    IReadOnlyList<PerDeviceMulticastRow> MulticastRows,
    IReadOnlyList<PerDeviceControlSubnetRow> ControlSubnetRows);
