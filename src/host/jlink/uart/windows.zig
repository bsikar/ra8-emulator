//! Windows: the J-Link composite device's instance ID ends in its USB serial;
//! its CDC child carries the COM port name in its hardware registry key.
const std = @import("std");

const emu_list = @import("../emu_list.zig");

const DEVINST = u32;
const HKEY = *opaque {};
const success: u32 = 0;
const filter_enumerator: u32 = 0x1;
const filter_present: u32 = 0x100;
const key_read: u32 = 0x20019;
const open_existing: u32 = 1;

extern "cfgmgr32" fn CM_Get_Device_ID_List_SizeW(len: *u32, filter: [*:0]const u16, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Get_Device_ID_ListW(
    filter: [*:0]const u16,
    buf: [*]u16,
    len: u32,
    flags: u32,
) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Locate_DevNodeW(inst: *DEVINST, id: [*:0]const u16, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Get_Child(child: *DEVINST, inst: DEVINST, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Get_Sibling(next: *DEVINST, inst: DEVINST, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Open_DevNode_Key(
    inst: DEVINST,
    access: u32,
    profile: u32,
    disposition: u32,
    key: *HKEY,
    flags: u32,
) callconv(.winapi) u32;
extern "advapi32" fn RegQueryValueExW(
    key: HKEY,
    name: [*:0]const u16,
    reserved: ?*u32,
    kind: ?*u32,
    data: ?[*]u8,
    len: *u32,
) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;

pub fn find(serial: u64, out: []u8) !?[]const u8 {
    const usb = std.unicode.utf8ToUtf16LeStringLiteral("USB");
    const flags = filter_enumerator | filter_present;
    var size: u32 = 0;
    if (CM_Get_Device_ID_List_SizeW(&size, usb, flags) != success) return error.DeviceListFailed;
    const ids = try std.heap.page_allocator.alloc(u16, size);
    defer std.heap.page_allocator.free(ids);
    if (CM_Get_Device_ID_ListW(usb, ids.ptr, size, flags) != success) return error.DeviceListFailed;
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u16, ids, 0);
    while (it.next()) |id| {
        if (id.len == 0 or id.len > 200) continue;
        var narrow: [200]u8 = undefined;
        for (id, 0..) |unit, i| {
            narrow[i] = if (unit < 0x80) @intCast(unit) else '?';
        }
        if (!matches(narrow[0..id.len], serial)) continue;
        if (found != null) return error.DuplicateSerial;
        var wide: [201:0]u16 = undefined;
        @memcpy(wide[0..id.len], id);
        wide[id.len] = 0;
        found = try portOf(wide[0..id.len :0], out);
    }
    return found;
}

/// Whether a device instance ID is the composite J-Link with `serial`
/// (`USB\VID_1366&PID_xxxx\001083322193`), not one of its interfaces.
pub fn matches(id: []const u8, serial: u64) bool {
    if (!std.ascii.startsWithIgnoreCase(id, "USB\\VID_1366&PID_")) return false;
    if (std.ascii.findIgnoreCase(id, "&MI_") != null) return false;
    var digits: [20]u8 = undefined;
    var wanted: [24]u8 = undefined;
    const tail = std.fmt.bufPrint(&wanted, "\\{s}", .{emu_list.format(serial, &digits)}) catch return false;
    return std.ascii.endsWithIgnoreCase(id, tail);
}

fn portOf(id: [:0]const u16, out: []u8) !?[]const u8 {
    var parent: DEVINST = 0;
    if (CM_Locate_DevNodeW(&parent, id.ptr, 0) != success) return null;
    var child: DEVINST = 0;
    if (CM_Get_Child(&child, parent, 0) != success) return null;
    while (true) {
        if (try portName(child, out)) |name| return name;
        if (CM_Get_Sibling(&child, child, 0) != success) return null;
    }
}

fn portName(inst: DEVINST, out: []u8) !?[]const u8 {
    var key: HKEY = undefined;
    if (CM_Open_DevNode_Key(inst, key_read, 0, open_existing, &key, 0) != success) return null;
    defer _ = RegCloseKey(key);
    var data: [64]u16 = undefined;
    var len: u32 = @sizeOf(@TypeOf(data));
    const name = std.unicode.utf8ToUtf16LeStringLiteral("PortName");
    if (RegQueryValueExW(key, name, null, null, @ptrCast(&data), &len) != 0) return null;
    const units = std.mem.sliceTo(data[0 .. len / 2], 0);
    if (units.len == 0 or units.len > out.len) return error.BadPortName;
    for (units, 0..) |unit, i| {
        if (unit >= 0x80) return error.BadPortName;
        out[i] = @intCast(unit);
    }
    return out[0..units.len];
}
