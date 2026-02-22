const std = @import("std");
const t = @import("types.zig");

pub fn clearSelection(state: *t.GameState) void {
    for (state.units[0..state.unit_count]) |*unit| {
        unit.selected = false;
    }
}

pub fn pickUnitAtWorld(state: *const t.GameState, world: t.Vec2) ?usize {
    var best_dist_sq: f32 = 999999.0;
    var best_idx: ?usize = null;

    var i: usize = 0;
    while (i < state.unit_count) : (i += 1) {
        const unit = state.units[i];
        const dx = unit.pos.x - world.x;
        const dy = unit.pos.y - world.y;
        const dist_sq = dx * dx + dy * dy;
        if (dist_sq < 0.65 * 0.65 and dist_sq < best_dist_sq) {
            best_dist_sq = dist_sq;
            best_idx = i;
        }
    }

    return best_idx;
}

pub fn selectByClick(state: *t.GameState, mouse: t.Vec2, additive: bool, screenToWorldFn: anytype) void {
    if (!additive) {
        clearSelection(state);
    }

    if (pickUnitAtWorld(state, screenToWorldFn(mouse))) |idx| {
        state.units[idx].selected = true;
    }
}

pub fn selectByBox(state: *t.GameState, a: t.Vec2, b: t.Vec2, additive: bool, worldToScreenFn: anytype) void {
    if (!additive) {
        clearSelection(state);
    }

    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);

    var i: usize = 0;
    while (i < state.unit_count) : (i += 1) {
        const p = worldToScreenFn(state.units[i].pos);
        if (p.x >= min_x and p.x <= max_x and p.y >= min_y and p.y <= max_y) {
            state.units[i].selected = true;
        }
    }
}

pub fn issueMoveOrder(state: *t.GameState, mouse: t.Vec2, screenToWorldFn: anytype, clampWorldFn: anytype) void {
    var selected: [t.MaxUnits]usize = undefined;
    var selected_count: usize = 0;

    var i: usize = 0;
    while (i < state.unit_count) : (i += 1) {
        if (state.units[i].selected) {
            selected[selected_count] = i;
            selected_count += 1;
        }
    }

    if (selected_count == 0) {
        return;
    }

    const target = clampWorldFn(screenToWorldFn(mouse));
    const cols: usize = @max(1, @as(usize, @intFromFloat(@ceil(std.math.sqrt(@as(f32, @floatFromInt(selected_count)))))));
    const rows: usize = (selected_count + cols - 1) / cols;

    const cols_half = (@as(f32, @floatFromInt(cols)) - 1.0) * 0.5;
    const rows_half = (@as(f32, @floatFromInt(rows)) - 1.0) * 0.5;
    const spacing: f32 = 0.85;

    i = 0;
    while (i < selected_count) : (i += 1) {
        const col = i % cols;
        const row = i / cols;

        const offset_x = (@as(f32, @floatFromInt(col)) - cols_half) * spacing;
        const offset_y = (@as(f32, @floatFromInt(row)) - rows_half) * spacing;

        state.units[selected[i]].target = clampWorldFn(.{
            .x = target.x + offset_x,
            .y = target.y + offset_y,
        });
    }
}

pub fn updateUnits(state: *t.GameState, dt: f32) void {
    for (state.units[0..state.unit_count]) |*unit| {
        const dx = unit.target.x - unit.pos.x;
        const dy = unit.target.y - unit.pos.y;
        const dist_sq = dx * dx + dy * dy;
        if (dist_sq <= 0.0001) {
            continue;
        }

        const dist = @sqrt(dist_sq);
        const step = @min(dist, unit.speed * dt);
        unit.pos.x += (dx / dist) * step;
        unit.pos.y += (dy / dist) * step;
    }
}
