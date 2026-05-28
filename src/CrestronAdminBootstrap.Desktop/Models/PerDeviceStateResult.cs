namespace CrestronAdminBootstrap.Desktop.Models;

public sealed record PerDeviceStateResult(
    IReadOnlyList<PerDeviceDeviceRow> DeviceRows,
    IReadOnlyList<PerDeviceAvDeviceRow> AvDeviceRows,
    IReadOnlyList<PerDeviceAvInputRow> AvInputRows,
    IReadOnlyList<PerDeviceAvOutputRow> AvOutputRows,
    IReadOnlyList<PerDeviceMulticastRow> MulticastRows,
    IReadOnlyList<PerDeviceControlSubnetRow> ControlSubnetRows);
