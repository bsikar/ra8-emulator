//! Adapter exposing an `Icu` event-link table through `irq_source.IrqSource`.
const icu = @import("icu.zig");
const irq_source = @import("../irq_source.zig");
const periph = @import("../registry.zig");

const cpu0_vtable = makeVTable(.cpu0);
const cpu1_vtable = makeVTable(.cpu1);

pub fn forIssuer(self: *icu.Icu, issuer: periph.Issuer) irq_source.IrqSource {
    return .{
        .ctx = self,
        .vtable = switch (issuer) {
            .cpu0 => &cpu0_vtable,
            .cpu1 => &cpu1_vtable,
        },
    };
}

fn makeVTable(comptime issuer: periph.Issuer) irq_source.IrqSource.VTable {
    const Impl = struct {
        fn raise(ctx: *anyopaque, sink: irq_source.Sink, irq_lines: u16, event: u16) irq_source.SinkError!void {
            const self: *icu.Icu = @ptrCast(@alignCast(ctx));
            const table = self.tableFor(issuer);
            const slot = icu.slotIn(table, event) orelse {
                self.unlinked += 1;
                return;
            };
            self.raised += 1;
            if (slot >= irq_lines or table[slot] & icu.field.ir != 0) return;
            table[slot] |= icu.field.ir;
            if (try sink.pend(@intCast(slot), irq_lines)) self.pends += 1;
        }

        fn repend(ctx: *anyopaque, sink: irq_source.Sink, irq_lines: u16) irq_source.SinkError!void {
            const self: *icu.Icu = @ptrCast(@alignCast(ctx));
            const limit: usize = @min(icu.slots, @as(usize, irq_lines));
            for (self.tableFor(issuer)[0..limit], 0..) |link, slot| {
                if (link & icu.field.ir == 0) continue;
                const line: u16 = @intCast(slot);
                if (try sink.isPending(line, irq_lines)) continue;
                if (try sink.pend(line, irq_lines)) self.repends += 1;
            }
        }

        fn asserted(ctx: *anyopaque, line: u16) bool {
            const self: *icu.Icu = @ptrCast(@alignCast(ctx));
            if (line >= icu.slots) return false;
            return self.tableFor(issuer)[line] & icu.field.ir != 0;
        }

        fn acknowledge(ctx: *anyopaque, line: u16) void {
            const self: *icu.Icu = @ptrCast(@alignCast(ctx));
            if (line >= icu.slots) return;
            self.tableFor(issuer)[line] &= ~icu.field.ir;
        }

        fn clearLatches(ctx: *anyopaque) void {
            const self: *icu.Icu = @ptrCast(@alignCast(ctx));
            self.clearLatches();
        }
    };
    return .{
        .raise = Impl.raise,
        .repend = Impl.repend,
        .asserted = Impl.asserted,
        .acknowledge = Impl.acknowledge,
        .clearLatches = Impl.clearLatches,
    };
}
