//! The names a history root and a session directory are made of.
//!
//!   ROOT/ra8-history-root   marks the directory as a history root
//!   ROOT/gate.lock          held while a directory is published or deleted
//!   ROOT/CACHEDIR.TAG       the ephemeral root only
//!   ROOT/ID.creating/       a session not yet published
//!   ROOT/ID/                a session: owner.lock owner incomplete [kept]
//!                           root.bin branches.bin log/ objects/ frames/
//!                           index/ scratch/
//!   ROOT/trash-ID/          a session on its way out
//!   ROOT/ID.pointer         kept root only: a kept session left where it was
const std = @import("std");
const builtin = @import("builtin");

pub const directory_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

/// Files at the top of a session directory.
pub const files = struct {
    pub const lock = "owner.lock";
    pub const owner = "owner";
    pub const incomplete = "incomplete";
    pub const kept = "kept";
    /// In either end of a directory move that has not ended.
    pub const moving = "moving";
    /// The one file rename a session has begun and not ended.
    pub const renaming = "renaming";
    pub const root = "root.bin";
    pub const branches = "branches.bin";
};

/// The directories inside a session directory.
pub const Space = enum { top, log, objects, frames, index, scratch };

pub const spaces = [_]Space{ .log, .objects, .frames, .index, .scratch };

/// Files at the top of a history root.
pub const root = struct {
    pub const marker = "ra8-history-root";
    pub const marker_text = "ra8-history-root 1\n";
    pub const kept_marker_text = "ra8-history-root 1\nkept\n";
    pub const runtime_marker_text = "ra8-runtime-root 1\n";
    pub const gate = "gate.lock";
    pub const tag = "CACHEDIR.TAG";
    pub const tag_text =
        "Signature: 8a477f597d28d172789f06886806bc55\n" ++
        "# This file is a cache directory tag created by ra8_emulator.\n" ++
        "# For information about cache directory tags see https://bford.info/cachedir/\n";
};

pub const affix = struct {
    pub const creating = ".creating";
    pub const pointer = ".pointer";
    /// Empty lock metadata parked while a Windows directory is published.
    pub const lease = ".lease";
    pub const trash = "trash-";
};

/// The first line of a session's `owner` file.
/// What the `moving` marker of a source says its move is for. A kept move
/// goes on to name the kept root, on a line of its own.
pub const moves = struct {
    pub const publish = "publish\n";
    pub const trash = "trash\n";
    pub const keep = "keep\n";
};

pub const owner_magic = "ra8-history-session 1";
