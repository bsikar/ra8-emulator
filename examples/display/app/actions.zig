//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What a tap can ask the app to do, and the one slot a widget callback
//! posts it into. ra8_widget callbacks carry no user pointer, so a widget
//! names its action in `action_id`: the low byte is the action, the high
//! byte an index (which key, which card). The app takes the slot after
//! every dispatch.

const rw = @import("ra8_widget");

const Widget = rw.types.Widget;

/// Every action a widget can post.
pub const Id = enum(u8) {
    none = 0,
    go_home,
    back,
    shell_tab,
    mdl_tab,
    open_player,
    play_pause,
    skip,
    previous,
    resume_book,
    open_recent,
    open_app,
    all_apps,
    open_library_item,
    open_equalizer,
    open_listen_row,
    volume_down,
    volume_up,
    eq_reset,
    band_down,
    band_up,
    open_setting,
    open_lock,
    key,
    reader_done,
    reader_library,
    open_work,
    continue_chapter,
    open_chapter,
    read_source,
    open_job,
    open_source_list,
    search_go,
    inert,
};

pub const Event = struct {
    id: Id,
    index: u16 = 0,
};

const index_shift = 8;
const id_mask: u16 = 0xFF;

var slot: ?Event = null;

/// The `action_id` a widget carries for `id` and `index`.
pub fn encode(id: Id, index: u8) u16 {
    return @as(u16, @backingInt(id)) | (@as(u16, index) << index_shift);
}

fn decode(action_id: u16) Id {
    return @fromBackingInt(@intCast(@as(u8, @intCast(action_id & id_mask))));
}

/// The action posted since the last take, if any.
pub fn take() ?Event {
    defer slot = null;
    return slot;
}

/// Button `on_press`: the index rides in the widget's own action id.
pub fn onPress(w: *Widget) callconv(.c) void {
    slot = .{ .id = decode(w.action_id), .index = w.action_id >> index_shift };
}

/// List `on_select`: the row's action id names the action and the list's
/// base index; the row's own position is the list's selection.
pub fn onRow(w: *Widget, action_id: u16) callconv(.c) void {
    const list: *const rw.list.List = @ptrCast(@alignCast(w.ctx orelse return));
    slot = .{ .id = decode(action_id), .index = (action_id >> index_shift) + list.selected };
}

/// Nav bar `on_select`: the tapped cell is the index.
pub fn onCell(w: *Widget, index: u16) callconv(.c) void {
    slot = .{ .id = decode(w.action_id), .index = index };
}
