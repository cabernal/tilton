const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sgl = sokol.gl;
const t = @import("types.zig");

pub const VisibleBounds = struct {
    start_x: i32,
    end_x: i32,
    start_y: i32,
    end_y: i32,
};

pub fn emitQuadCentered(cx: f32, cy: f32, w: f32, h: f32) void {
    const x0 = cx - w * 0.5;
    const y0 = cy - h * 0.5;
    const x1 = x0 + w;
    const y1 = y0 + h;

    sgl.v2fT2f(x0, y0, 0.0, 0.0);
    sgl.v2fT2f(x1, y0, 1.0, 0.0);
    sgl.v2fT2f(x1, y1, 1.0, 1.0);
    sgl.v2fT2f(x0, y1, 0.0, 1.0);
}

pub fn emitQuadBottom(cx: f32, by: f32, w: f32, h: f32) void {
    const x0 = cx - w * 0.5;
    const y0 = by - h;
    const x1 = x0 + w;
    const y1 = by;

    sgl.v2fT2f(x0, y0, 0.0, 0.0);
    sgl.v2fT2f(x1, y0, 1.0, 0.0);
    sgl.v2fT2f(x1, y1, 1.0, 1.0);
    sgl.v2fT2f(x0, y1, 0.0, 1.0);
}

pub fn emitQuadBottomZRotated(world: t.Vec2, draw_h: f32, width_tiles: f32, rot: u8, worldToScreenFn: anytype) void {
    const angle = (@as(f32, @floatFromInt(rot % 4)) * std.math.pi) * 0.5;
    const dir = t.Vec2{
        .x = @cos(angle),
        .y = @sin(angle),
    };
    const half_w = width_tiles * 0.5;

    const bottom_l = worldToScreenFn(.{
        .x = world.x - dir.x * half_w,
        .y = world.y - dir.y * half_w,
    });
    const bottom_r = worldToScreenFn(.{
        .x = world.x + dir.x * half_w,
        .y = world.y + dir.y * half_w,
    });
    const top_l = t.Vec2{ .x = bottom_l.x, .y = bottom_l.y - draw_h };
    const top_r = t.Vec2{ .x = bottom_r.x, .y = bottom_r.y - draw_h };

    sgl.v2fT2f(top_l.x, top_l.y, 0.0, 0.0);
    sgl.v2fT2f(top_r.x, top_r.y, 1.0, 0.0);
    sgl.v2fT2f(bottom_r.x, bottom_r.y, 1.0, 1.0);
    sgl.v2fT2f(bottom_l.x, bottom_l.y, 0.0, 1.0);
}

pub fn computeVisibleBounds(screenToWorldFn: anytype) VisibleBounds {
    const corners = [_]t.Vec2{
        screenToWorldFn(.{ .x = 0, .y = 0 }),
        screenToWorldFn(.{ .x = sapp.widthf(), .y = 0 }),
        screenToWorldFn(.{ .x = 0, .y = sapp.heightf() }),
        screenToWorldFn(.{ .x = sapp.widthf(), .y = sapp.heightf() }),
    };

    var min_x = corners[0].x;
    var max_x = corners[0].x;
    var min_y = corners[0].y;
    var max_y = corners[0].y;

    for (corners[1..]) |c| {
        min_x = @min(min_x, c.x);
        max_x = @max(max_x, c.x);
        min_y = @min(min_y, c.y);
        max_y = @max(max_y, c.y);
    }

    return .{
        .start_x = @max(0, @as(i32, @intFromFloat(@floor(min_x))) - 3),
        .end_x = @min(t.MapW - 1, @as(i32, @intFromFloat(@ceil(max_x))) + 3),
        .start_y = @max(0, @as(i32, @intFromFloat(@floor(min_y))) - 3),
        .end_y = @min(t.MapH - 1, @as(i32, @intFromFloat(@ceil(max_y))) + 3),
    };
}

pub fn drawMap(state: *const t.GameState, screenToWorldFn: anytype, worldToScreenFn: anytype) void {
    const bounds = computeVisibleBounds(screenToWorldFn);

    if (state.tile_count == 0) {
        return;
    }

    sgl.loadPipeline(state.alpha_pipeline);
    sgl.enableTexture();

    var tile_idx: usize = 0;
    while (tile_idx < state.tile_count) : (tile_idx += 1) {
        const tile = state.tile_sprites[tile_idx];
        const draw_w = tile.width * state.zoom;
        const draw_h = tile.height * state.zoom;

        sgl.texture(tile.view, state.sampler);
        sgl.beginQuads();

        var y: i32 = bounds.start_y;
        while (y <= bounds.end_y) : (y += 1) {
            var x: i32 = bounds.start_x;
            while (x <= bounds.end_x) : (x += 1) {
                const raw = state.map_floor[@intCast(y)][@intCast(x)];
                if (raw == t.EmptyFloorTile) {
                    continue;
                }
                if (@as(usize, raw % @as(u8, @intCast(state.tile_count))) != tile_idx) {
                    continue;
                }
                const world = t.Vec2{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                };
                const screen = worldToScreenFn(world);
                sgl.c4f(1.0, 1.0, 1.0, 1.0);
                emitQuadCentered(screen.x, screen.y, draw_w, draw_h);
            }
        }

        sgl.end();
    }

    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

pub fn drawStructureLayer(
    state: *const t.GameState,
    map_layer: *const [t.MapH][t.MapW]u8,
    rot_layer: *const [t.MapH][t.MapW]u8,
    sprites: []const t.Sprite,
    sprite_count: usize,
    screenToWorldFn: anytype,
    worldToScreenFn: anytype,
) void {
    if (sprite_count == 0) {
        return;
    }
    const bounds = computeVisibleBounds(screenToWorldFn);

    sgl.loadPipeline(state.alpha_pipeline);
    sgl.enableTexture();

    const structure_scale = @max(1.0, state.tile_world_w / 64.0);

    var sprite_idx: usize = 0;
    while (sprite_idx < sprite_count) : (sprite_idx += 1) {
        const sprite = sprites[sprite_idx];
        const draw_w = sprite.width * state.zoom * structure_scale;
        const draw_h = sprite.height * state.zoom * structure_scale;
        const width_tiles = @max(0.35, draw_w / (state.tile_world_w * state.zoom));

        sgl.texture(sprite.view, state.sampler);
        sgl.beginQuads();

        var y: i32 = bounds.start_y;
        while (y <= bounds.end_y) : (y += 1) {
            var x: i32 = bounds.start_x;
            while (x <= bounds.end_x) : (x += 1) {
                const raw = map_layer[@intCast(y)][@intCast(x)];
                if (raw == 0 or @as(usize, raw - 1) != sprite_idx) {
                    continue;
                }

                const world = t.Vec2{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                };
                sgl.c4f(1.0, 1.0, 1.0, 1.0);
                emitQuadBottomZRotated(world, draw_h, width_tiles, rot_layer[@intCast(y)][@intCast(x)], worldToScreenFn);
            }
        }
        sgl.end();
    }

    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

pub fn drawUnits(state: *const t.GameState, worldToScreenFn: anytype) void {
    var order: [t.MaxUnits]usize = undefined;
    for (0..state.unit_count) |i| {
        order[i] = i;
    }

    var i: usize = 1;
    while (i < state.unit_count) : (i += 1) {
        const key = order[i];
        const key_depth = state.units[key].pos.x + state.units[key].pos.y;
        var j = i;
        while (j > 0) {
            const prev = order[j - 1];
            const prev_depth = state.units[prev].pos.x + state.units[prev].pos.y;
            if (prev_depth <= key_depth) {
                break;
            }
            order[j] = prev;
            j -= 1;
        }
        order[j] = key;
    }

    const blue_w = state.unit_blue_sprite.width * state.zoom;
    const blue_h = state.unit_blue_sprite.height * state.zoom;
    const red_w = state.unit_red_sprite.width * state.zoom;
    const red_h = state.unit_red_sprite.height * state.zoom;

    sgl.enableTexture();

    sgl.texture(state.unit_blue_sprite.view, state.sampler);
    sgl.beginQuads();
    for (order[0..state.unit_count]) |idx| {
        const unit = state.units[idx];
        if (unit.team != 0) continue;

        const screen = worldToScreenFn(unit.pos);
        sgl.c4f(1.0, 1.0, 1.0, 1.0);
        emitQuadBottom(screen.x, screen.y, blue_w, blue_h);
    }
    sgl.end();

    sgl.texture(state.unit_red_sprite.view, state.sampler);
    sgl.beginQuads();
    for (order[0..state.unit_count]) |idx| {
        const unit = state.units[idx];
        if (unit.team != 1) continue;

        const screen = worldToScreenFn(unit.pos);
        sgl.c4f(1.0, 1.0, 1.0, 1.0);
        emitQuadBottom(screen.x, screen.y, red_w, red_h);
    }
    sgl.end();

    sgl.disableTexture();
    sgl.loadDefaultPipeline();

    for (state.units[0..state.unit_count]) |unit| {
        if (!unit.selected) continue;

        const screen = worldToScreenFn(unit.pos);
        const rx = state.tile_world_w * 0.30 * state.zoom;
        const ry = state.tile_world_h * 0.22 * state.zoom;

        sgl.c4f(0.20, 0.95, 0.20, 0.95);
        sgl.beginLineStrip();
        sgl.v2f(screen.x, screen.y - ry);
        sgl.v2f(screen.x + rx, screen.y);
        sgl.v2f(screen.x, screen.y + ry);
        sgl.v2f(screen.x - rx, screen.y);
        sgl.v2f(screen.x, screen.y - ry);
        sgl.end();
    }
}

pub fn drawSelectionBox(drag: t.DragState) void {
    if (!drag.active or !drag.box_select) {
        return;
    }

    const a = drag.start;
    const b = drag.current;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);

    sgl.disableTexture();

    sgl.c4f(0.2, 0.9, 0.4, 0.15);
    sgl.beginQuads();
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();

    sgl.c4f(0.2, 0.9, 0.4, 0.95);
    sgl.beginLineStrip();
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.v2f(x0, y0);
    sgl.end();
}
