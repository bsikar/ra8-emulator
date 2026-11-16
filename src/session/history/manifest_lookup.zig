//! Binary lookup in manifest pages ordered by address space and page index.
const manifest_mod = @import("manifest.zig");
const ObjectId = @import("object_id.zig").ObjectId;

pub fn findPage(pages: []const manifest_mod.PageRef, space: manifest_mod.SpaceId, page_index: u32) ?ObjectId {
    var low: usize = 0;
    var high: usize = pages.len;
    const target_space = @backingInt(space);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mid_item = pages[mid];
        const item_space = @backingInt(mid_item.space);
        if (target_space < item_space) {
            high = mid;
        } else if (target_space > item_space) {
            low = mid + 1;
        } else if (page_index < mid_item.page_index) {
            high = mid;
        } else if (page_index > mid_item.page_index) {
            low = mid + 1;
        } else {
            return mid_item.object;
        }
    }
    return null;
}
