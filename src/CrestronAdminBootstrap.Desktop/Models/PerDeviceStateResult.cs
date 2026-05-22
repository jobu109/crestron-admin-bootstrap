namespace CrestronAdminBootstrap.Desktop.Models;

public sealed record PerDeviceStateResult(
    IReadOnlyList<PerDeviceDeviceRow> DeviceRows,
    IReadOnlyList<PerDeviceAvInputRow> AvInputRows,
    IReadOnlyList<PerDeviceAvOutputRow> AvOutputRows,
    IReadOnlyList<PerDeviceMulticastRow> MulticastRows,
    IReadOnlyList<PerDeviceControlSubnetRow> ControlSubnetRows);
