//! The pure composition path: what the panel would show, without
//! touching a thing (RA8EMU-D13). A scan out of the block raises VPOS,
//! counts frames and feeds the meters; a viewer or a frame tap must never
//! do that by asking for a picture. So the picture they get is composed
//! over copies of the block's state: `inputs` copies everything a
//! composition would reach for, `compose` runs the mixer's own stack over
//! those copies, and nothing in the model moves. The refusals are the
//! ones a scan of the same state would give.
const glcdc_mod = @import("glcdc.zig");
const blend = @import("blend.zig");
const mix = @import("mix.zig");
const Glcdc = glcdc_mod.Glcdc;

/// The copied inputs for a pure composition of this block as it stands.
/// Null when the block has no guest memory to read from.
pub fn inputs(self: *const Glcdc) ?mix.Source {
    const memory = self.memory orelse return null;
    var source: mix.Source = .{ .memory = memory };
    source.width = self.panelWidth();
    source.height = self.panelHeight();
    source.background = self.word(glcdc_mod.off.bg_bgc);
    source.stage = self.output;
    const origin: blend.Origin = if (self.timing.timing()) |found|
        .{ .left = found.h_back, .top = found.v_back }
    else
        .{};
    for (1..mix.layers + 1) |layer| {
        const found = self.decode(@intCast(layer)) orelse continue;
        var placement = self.blends[layer - 1];
        placement.origin = origin;
        if (placement.quiet()) placement = blend.implied(found.width, found.height);
        source.planes[source.count] = .{
            .shape = glcdc_mod.shapeOf(found),
            .palette = self.palettes[layer - 1],
            .stage = placement,
        };
        source.count += 1;
    }
    return source;
}

/// Compose the panel from `source` into `into`, purely.
pub fn composite(self: *const Glcdc, source: mix.Source, powered: bool, into: []u32) mix.Result {
    if (!powered) return .{ .refused = .no_layer };
    if (self.framebuffer()) |shown| {
        if (!shown.enabled) return .{ .refused = .output_off };
    } else {
        // The backdrop: a background-only frame when no graphics layer is
        // fetching at all, and a refusal when one says it is but cannot
        // be believed (the fetch would underflow on silicon).
        if (glcdc_mod.backdrop.anyLayerReading(self)) return .{ .refused = .no_layer };
        if (!self.outputEnabled()) return .{ .refused = .no_layer };
    }
    if (!self.system.clocked()) return .{ .refused = .unclocked };
    if (source.width == 0 or source.height == 0) return .{ .refused = .no_layer };
    return mix.compose(source, into);
}
