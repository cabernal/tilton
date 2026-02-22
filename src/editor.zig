const t = @import("types.zig");
const sapp = @import("sokol").app;

pub fn activeTileCount(state: *const t.GameState) usize {
    return if (state.tile_count == 0) 1 else state.tile_count;
}

pub fn activeWallCount(state: *const t.GameState) usize {
    return state.wall_count;
}

pub fn activeRoofCount(state: *const t.GameState) usize {
    return state.roof_count;
}

fn worldToCell(world: t.Vec2) ?struct { x: i32, y: i32 } {
    const cx: i32 = @intFromFloat(@floor(world.x));
    const cy: i32 = @intFromFloat(@floor(world.y));
    if (cx < 0 or cx >= t.MapW or cy < 0 or cy >= t.MapH) {
        return null;
    }
    return .{ .x = cx, .y = cy };
}

pub fn paintAtWorld(state: *t.GameState, world: t.Vec2, erase: bool) void {
    const center = worldToCell(world) orelse return;
    const r = state.brush_radius;
    var oy: i32 = -r;
    while (oy <= r) : (oy += 1) {
        var ox: i32 = -r;
        while (ox <= r) : (ox += 1) {
            if (@abs(ox) + @abs(oy) > r) continue;
            const x = center.x + ox;
            const y = center.y + oy;
            if (x < 0 or x >= t.MapW or y < 0 or y >= t.MapH) continue;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            switch (state.editor_layer) {
                .floor => {
                    if (erase) {
                        state.map_floor[uy][ux] = t.EmptyFloorTile;
                    } else {
                        const count = activeTileCount(state);
                        state.map_floor[uy][ux] = state.brush_floor_tile % @as(u8, @intCast(count));
                    }
                },
                .wall => {
                    if (activeWallCount(state) == 0) continue;
                    if (erase or state.brush_wall_tile == 0) {
                        state.map_wall[uy][ux] = 0;
                        state.map_wall_rot[uy][ux] = 0;
                    } else {
                        const count_u8: u8 = @intCast(activeWallCount(state));
                        state.map_wall[uy][ux] = ((state.brush_wall_tile - 1) % count_u8) + 1;
                        state.map_wall_rot[uy][ux] = state.brush_wall_rot % 4;
                    }
                },
                .roof => {
                    if (activeRoofCount(state) == 0) continue;
                    if (erase or state.brush_roof_tile == 0) {
                        state.map_roof[uy][ux] = 0;
                        state.map_roof_rot[uy][ux] = 0;
                    } else {
                        const count_u8: u8 = @intCast(activeRoofCount(state));
                        state.map_roof[uy][ux] = ((state.brush_roof_tile - 1) % count_u8) + 1;
                        state.map_roof_rot[uy][ux] = state.brush_roof_rot % 4;
                    }
                },
            }
        }
    }
}

pub fn pickTileAtWorld(state: *t.GameState, world: t.Vec2) void {
    const cell = worldToCell(world) orelse return;
    const x: usize = @intCast(cell.x);
    const y: usize = @intCast(cell.y);
    switch (state.editor_layer) {
        .floor => {
            const raw = state.map_floor[y][x];
            if (raw != t.EmptyFloorTile) {
                state.brush_floor_tile = raw % @as(u8, @intCast(activeTileCount(state)));
            }
        },
        .wall => {
            if (activeWallCount(state) == 0) {
                state.brush_wall_tile = 0;
                state.brush_wall_rot = 0;
            } else {
                state.brush_wall_tile = @min(state.map_wall[y][x], @as(u8, @intCast(activeWallCount(state))));
                state.brush_wall_rot = state.map_wall_rot[y][x] % 4;
            }
        },
        .roof => {
            if (activeRoofCount(state) == 0) {
                state.brush_roof_tile = 0;
                state.brush_roof_rot = 0;
            } else {
                state.brush_roof_tile = @min(state.map_roof[y][x], @as(u8, @intCast(activeRoofCount(state))));
                state.brush_roof_rot = state.map_roof_rot[y][x] % 4;
            }
        },
    }
}

pub fn numberKeyFromKeycode(key: sapp.Keycode) ?u8 {
    return switch (key) {
        ._0 => 0,
        ._1 => 1,
        ._2 => 2,
        ._3 => 3,
        ._4 => 4,
        ._5 => 5,
        ._6 => 6,
        ._7 => 7,
        ._8 => 8,
        else => null,
    };
}

pub fn applyNumberBrushShortcut(state: *t.GameState, number_key: u8) void {
    switch (state.editor_layer) {
        .floor => {
            if (number_key == 0) return;
            const idx = number_key - 1;
            if (@as(usize, idx) < state.tile_count) {
                state.brush_floor_tile = idx;
            }
        },
        .wall => {
            if (number_key == 0) {
                state.brush_wall_tile = 0;
                return;
            }
            if (@as(usize, number_key) <= state.wall_count) {
                state.brush_wall_tile = number_key;
            }
        },
        .roof => {
            if (number_key == 0) {
                state.brush_roof_tile = 0;
                return;
            }
            if (@as(usize, number_key) <= state.roof_count) {
                state.brush_roof_tile = number_key;
            }
        },
    }
}
