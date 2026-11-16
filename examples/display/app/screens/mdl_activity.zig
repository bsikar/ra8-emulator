//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M7 Activity: the download queue, one job a row.

const tree = @import("../tree.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const job_height: i16 = 140;
const per_page: u16 = 5;
const queued: u16 = 9;
const row_cap = 8;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const jobs = ctx.svc.mdl.jobs();
    var rows: [row_cap]tree.Row = undefined;
    const count = @min(jobs.len, row_cap);
    for (jobs[0..count], rows[0..count]) |job, *row| {
        row.* = .{ .title = try b.fmt("{s} - {s}", .{ job.title, job.what }), .subtitle = job.state, .value = job.action };
    }

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    try header.add(b, &body, "Activity", .{ .aside = try header.note(b, "1 downloading - 1 queued - 1 failed"), .aside_width = 420 });
    try body.add(try b.named("activity.jobs", try b.list(rows[0..count], job_height, .open_job, 0)));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, queued, per_page, ctx.state.activity_page, .activity_page);
    try bars.mdl(b, &root, 2);
    return b.col(0, root.slice());
}
