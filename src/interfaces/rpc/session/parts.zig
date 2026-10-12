//! The plug, unplug and fault handlers (RA8EMU-749): the Session's plug
//! hook (RA8EMU-212) and fault hook (RA8EMU-520) over the wire.
//!
//! Each request carries the part spec as text in the CLI's own syntax and
//! the server parses it with the same parsers `--attach` and `--fault`
//! use, so the two syntaxes cannot drift. A spec that does not parse is
//! `bad_args`; one the board cannot honour is `refused`. list_parts
//! (RA8EMU-791) answers in the same syntax plug takes.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const endpoint = @import("ra8_components").endpoint;
const request = @import("ra8_components").request;
const fault_spec = @import("ra8_components").fault.spec;
const board_lib = @import("ra8_board");
const chip_gpio = @import("ra8_chip").periph.gpio;

const Context = handlers.Context;
const Ack = rpc.Outcome(proto.Ack);
const ack: Ack = .{ .ok = .{ .accepted = 1 } };

fn core(of: proto.Core) @import("ra8_session").api.Core {
    return @fromBackingInt(@intCast(@backingInt(of)));
}

fn refused(err: anyerror) Ack {
    std.debug.print("serve: {s}\n", .{@errorName(err)});
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

/// `MODEL@ENDPOINT`: a fresh part of that model on that endpoint.
pub fn plug(context: *Context, args: proto.PartSpec) Ack {
    const wanted = request.parse(args.text) catch return .{ .err = .bad_args };
    context.session.plug(core(args.core), wanted.at, wanted.name) catch |err| return refused(err);
    return ack;
}

/// `ENDPOINT`: take whatever sits there off it.
pub fn unplug(context: *Context, args: proto.PartSpec) Ack {
    const at = endpoint.parse(args.text) catch return .{ .err = .bad_args };
    context.session.unplug(core(args.core), at) catch |err| return refused(err);
    return ack;
}

/// `MODEL@ENDPOINT=MODE` or `@ENDPOINT=MODE`: the part there misbehaves
/// that way from now on, mid-run included.
pub fn setFault(context: *Context, args: proto.PartSpec) Ack {
    const wanted = fault_spec.parse(args.text) catch return .{ .err = .bad_args };
    context.session.setFault(core(args.core), wanted.target.at, wanted.mode) catch |err| return refused(err);
    return ack;
}

/// `ENDPOINT`: the part there behaves like the part again.
pub fn clearFault(context: *Context, args: proto.PartSpec) Ack {
    const at = endpoint.parse(args.text) catch return .{ .err = .bad_args };
    context.session.clearFault(core(args.core), at) catch |err| return refused(err);
    return ack;
}

/// The fitted parts, one `MODEL@ENDPOINT` line each.
pub fn listParts(context: *Context, _: proto.CoreOnly) rpc.Outcome(proto.PartList) {
    const listing = context.listing orelse return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    const room = @min(context.scratch.len, proto.PartList.max_len.text);
    const text = listing.listFn(listing.context, context.scratch[0..room]) catch |err| {
        if (err == error.NoSpaceLeft) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    return .{ .ok = .{ .text = text } };
}

/// The served board's front-panel parts (RA8EMU-1151): each LED's label in
/// the chip's led_changed order with its lamp colour, each switch's label in
/// the board's switch order, and the panel profile (or none). The GUI reads
/// the board only through this answer, so the pane draws what the board has
/// and carries no board knowledge of its own.
pub fn boardParts(context: *Context, _: proto.CoreOnly) rpc.Outcome(proto.BoardParts) {
    const profile = if (context.board_profile) |given| given.* else board_lib.profile.parse(board_lib.profile.ek_ra8d2) catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    var rest = context.scratch;
    const panel = take(&rest, proto.BoardParts.max_len.panel);
    const led_names = take(&rest, proto.BoardParts.max_len.led_names);
    const led_colors = take(&rest, proto.BoardParts.max_len.led_colors);
    const switch_names = take(&rest, proto.BoardParts.max_len.switch_names);

    var colors: usize = 0;
    var names: usize = 0;
    for (chip_gpio.leds) |led| {
        const entry = profile.ledAt(led.port, led.pin) orelse continue;
        if (colors + 2 > led_colors.len or !put(led_names, &names, entry.label)) return tooLong();
        led_colors[colors] = @truncate(entry.rgb565);
        led_colors[colors + 1] = @truncate(entry.rgb565 >> 8);
        colors += 2;
    }
    var switches: usize = 0;
    for (board_lib.switches.user) |one| {
        const entry = profile.switchAt(one.port, one.pin) orelse continue;
        if (!put(switch_names, &switches, entry.label)) return tooLong();
    }
    const stem: []const u8 = if (profile.panel) |glass| glass.name else "";
    const given = @min(stem.len, panel.len);
    @memcpy(panel[0..given], stem[0..given]);
    return .{ .ok = .{
        .panel = panel[0..given],
        .panel_width = if (profile.panel) |glass| glass.width else 0,
        .panel_height = if (profile.panel) |glass| glass.height else 0,
        .led_names = led_names[0..names],
        .led_colors = led_colors[0..colors],
        .switch_names = switch_names[0..switches],
    } };
}

fn tooLong() rpc.Outcome(proto.BoardParts) {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
}

/// Carves `room` bytes of reply storage off the scratch buffer.
fn take(rest: *[]u8, room: usize) []u8 {
    const slice = rest.*[0..@min(room, rest.*.len)];
    rest.* = rest.*[slice.len..];
    return slice;
}

/// Appends `text` as one line, '\n'-separated with no trailing newline;
/// false when it no longer fits.
fn put(lines: []u8, at: *usize, text: []const u8) bool {
    const room: usize = if (at.* > 0) text.len + 1 else text.len;
    if (at.* + room > lines.len) return false;
    if (at.* > 0) {
        lines[at.*] = '\n';
        at.* += 1;
    }
    @memcpy(lines[at.*..][0..text.len], text);
    at.* += text.len;
    return true;
}
