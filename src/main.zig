const std = @import("std");
const builtin = @import("builtin");
const png_loader = @import("png_loader.zig");

const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const sglue = sokol.glue;
const slog = sokol.log;

const MapW = 48;
const MapH = 48;
const MaxUnits = 48;
const TileVariants = 8;
const MapSavePath = "assets/map_layout.bin";
const MapSaveMagic = [_]u8{ 'T', 'L', 'T', 'N' };
const MapFormatVersionCurrent: u16 = 2;
const MapFormatVersionLegacy: u16 = 1;
const HudMessageSeconds: f32 = 2.6;

const HudTone = enum {
    info,
    success,
    warning,
    failure,
};

const HudPalette = struct {
    r: f32,
    g: f32,
    b: f32,
    tr: u8,
    tg: u8,
    tb: u8,
};

const Vec2 = struct {
    x: f32,
    y: f32,
};

const Sprite = struct {
    image: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,

    fn isValid(self: Sprite) bool {
        return self.image.id != 0 and self.view.id != 0;
    }
};

const Unit = struct {
    pos: Vec2,
    target: Vec2,
    speed: f32,
    team: u8,
    selected: bool = false,
};

const DragState = struct {
    active: bool = false,
    box_select: bool = false,
    start: Vec2 = .{ .x = 0, .y = 0 },
    current: Vec2 = .{ .x = 0, .y = 0 },
};

const GameState = struct {
    pass_action: sg.PassAction = .{},
    keys: [512]bool = [_]bool{false} ** 512,

    tile_world_w: f32 = 64,
    tile_world_h: f32 = 32,

    camera_iso: Vec2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,
    mouse_screen: Vec2 = .{ .x = 0, .y = 0 },
    drag: DragState = .{},
    paint_active: bool = false,
    editor_mode: bool = false,
    brush_tile: u8 = 0,
    brush_radius: i32 = 0,

    sampler: sg.Sampler = .{},
    alpha_pipeline: sgl.Pipeline = .{},
    tile_sprites: [TileVariants]Sprite = [_]Sprite{.{}} ** TileVariants,
    tile_count: usize = 0,
    unit_blue_sprite: Sprite = .{},
    unit_red_sprite: Sprite = .{},

    map: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    units: [MaxUnits]Unit = undefined,
    unit_count: usize = 0,

    hud_tone: HudTone = .info,
    hud_message: [160]u8 = [_]u8{0} ** 160,
    hud_message_len: usize = 0,
    hud_time_left: f32 = 0.0,

    initialized: bool = false,
};

var state: GameState = .{};

fn canPersistMap() bool {
    return !builtin.target.cpu.arch.isWasm();
}

fn hasCommandModifier(modifiers: u32) bool {
    return (modifiers & sapp.modifier_ctrl) != 0 or (modifiers & sapp.modifier_super) != 0;
}

fn setHudMessage(tone: HudTone, seconds: f32, comptime fmt: []const u8, args: anytype) void {
    const max_len = state.hud_message.len - 1;
    const text = std.fmt.bufPrint(state.hud_message[0..max_len], fmt, args) catch {
        const fallback = "status message too long";
        const n = @min(fallback.len, max_len);
        @memcpy(state.hud_message[0..n], fallback[0..n]);
        state.hud_message[n] = 0;
        state.hud_message_len = n;
        state.hud_tone = .warning;
        state.hud_time_left = seconds;
        return;
    };
    state.hud_message_len = text.len;
    state.hud_message[state.hud_message_len] = 0;
    state.hud_tone = tone;
    state.hud_time_left = seconds;
}

fn mapPayloadLen() usize {
    return MapW * MapH;
}

fn mapFileLegacySize() u64 {
    return MapSaveMagic.len + 4 + mapPayloadLen();
}

fn mapFileCurrentSize() u64 {
    return MapSaveMagic.len + 2 + 4 + mapPayloadLen();
}

fn readExact(file: *std.fs.File, dst: []u8) !void {
    const read_len = try file.readAll(dst);
    if (read_len != dst.len) {
        return error.UnexpectedEof;
    }
}

fn saveMapToDisk() !void {
    if (!canPersistMap()) {
        return error.UnsupportedPlatform;
    }

    const map_bytes = std.mem.asBytes(&state.map);
    var file = try std.fs.cwd().createFile(MapSavePath, .{ .truncate = true });
    defer file.close();

    try file.writeAll(&MapSaveMagic);

    var version_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, version_bytes[0..2], MapFormatVersionCurrent, .little);
    try file.writeAll(&version_bytes);

    var dims: [4]u8 = undefined;
    std.mem.writeInt(u16, dims[0..2], @as(u16, MapW), .little);
    std.mem.writeInt(u16, dims[2..4], @as(u16, MapH), .little);
    try file.writeAll(&dims);
    try file.writeAll(map_bytes);
}

fn tryLoadMapFromDisk(report_missing: bool, report_hud: bool) void {
    if (!canPersistMap()) {
        if (report_hud) {
            setHudMessage(.warning, HudMessageSeconds, "Map save/load unsupported in web build", .{});
        }
        return;
    }

    const map_bytes = std.mem.asBytes(&state.map);

    var file = std.fs.cwd().openFile(MapSavePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (report_missing) {
                std.log.info("No saved map found at {s}", .{MapSavePath});
            }
            if (report_hud) {
                setHudMessage(.info, HudMessageSeconds, "No saved map at {s}", .{MapSavePath});
            }
            return;
        }
        std.log.warn("Could not open map file {s}: {s}", .{ MapSavePath, @errorName(err) });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Failed opening map file", .{});
        }
        return;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.log.warn("Could not stat map file {s}: {s}", .{ MapSavePath, @errorName(err) });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Failed reading map metadata", .{});
        }
        return;
    };

    var magic: [MapSaveMagic.len]u8 = undefined;
    readExact(&file, &magic) catch |err| {
        std.log.warn("Failed reading map header from {s}: {s}", .{ MapSavePath, @errorName(err) });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Failed reading map header", .{});
        }
        return;
    };
    if (!std.mem.eql(u8, &magic, &MapSaveMagic)) {
        std.log.warn("Ignoring map file {s}: invalid magic", .{MapSavePath});
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Map file is invalid", .{});
        }
        return;
    }

    var loaded_version: u16 = 0;
    if (stat.size == mapFileCurrentSize()) {
        var version_bytes: [2]u8 = undefined;
        readExact(&file, &version_bytes) catch |err| {
            std.log.warn("Failed reading map version from {s}: {s}", .{ MapSavePath, @errorName(err) });
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Failed reading map version", .{});
            }
            return;
        };
        loaded_version = std.mem.readInt(u16, version_bytes[0..2], .little);
    } else if (stat.size == mapFileLegacySize()) {
        loaded_version = MapFormatVersionLegacy;
    } else {
        std.log.warn(
            "Ignoring map file {s}: unsupported size {d} bytes",
            .{ MapSavePath, stat.size },
        );
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Map file size is unsupported", .{});
        }
        return;
    }

    if (loaded_version == 0 or loaded_version > MapFormatVersionCurrent) {
        std.log.warn(
            "Ignoring map file {s}: unsupported version {d}",
            .{ MapSavePath, loaded_version },
        );
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Map version {d} is unsupported", .{loaded_version});
        }
        return;
    }

    var dims: [4]u8 = undefined;
    readExact(&file, &dims) catch |err| {
        std.log.warn("Failed reading map dimensions from {s}: {s}", .{ MapSavePath, @errorName(err) });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Failed reading map dimensions", .{});
        }
        return;
    };
    const w = std.mem.readInt(u16, dims[0..2], .little);
    const h = std.mem.readInt(u16, dims[2..4], .little);
    if (w != MapW or h != MapH) {
        std.log.warn("Ignoring map file {s}: expected {d}x{d}, got {d}x{d}", .{ MapSavePath, MapW, MapH, w, h });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Map dimensions mismatch ({d}x{d})", .{ w, h });
        }
        return;
    }

    readExact(&file, map_bytes) catch |err| {
        std.log.warn("Failed reading map payload from {s}: {s}", .{ MapSavePath, @errorName(err) });
        if (report_hud) {
            setHudMessage(.failure, HudMessageSeconds, "Failed reading map payload", .{});
        }
        return;
    };
    std.log.info("Loaded map layout from {s} (format v{d})", .{ MapSavePath, loaded_version });

    if (loaded_version < MapFormatVersionCurrent) {
        saveMapToDisk() catch |err| {
            std.log.warn(
                "Loaded map format v{d} but migration to v{d} failed: {s}",
                .{ loaded_version, MapFormatVersionCurrent, @errorName(err) },
            );
            if (report_hud) {
                setHudMessage(
                    .warning,
                    HudMessageSeconds + 0.8,
                    "Loaded map v{d}; migration to v{d} failed",
                    .{ loaded_version, MapFormatVersionCurrent },
                );
            }
            return;
        };
        std.log.info(
            "Migrated map format from v{d} to v{d}",
            .{ loaded_version, MapFormatVersionCurrent },
        );
        if (report_hud) {
            setHudMessage(
                .success,
                HudMessageSeconds + 0.8,
                "Loaded map v{d} and migrated to v{d}",
                .{ loaded_version, MapFormatVersionCurrent },
            );
        }
        return;
    }

    if (report_hud) {
        setHudMessage(.success, HudMessageSeconds, "Loaded map v{d}", .{loaded_version});
    }
}

fn assetPath(comptime rel: []const u8) []const u8 {
    return if (builtin.target.cpu.arch.isWasm()) "/assets/" ++ rel else "assets/" ++ rel;
}

fn clamp(v: f32, lo: f32, hi: f32) f32 {
    return @min(@max(v, lo), hi);
}

fn worldToIso(world: Vec2) Vec2 {
    const hw = state.tile_world_w * 0.5;
    const hh = state.tile_world_h * 0.5;
    return .{
        .x = (world.x - world.y) * hw,
        .y = (world.x + world.y) * hh,
    };
}

fn worldToScreen(world: Vec2) Vec2 {
    const iso = worldToIso(world);
    return .{
        .x = (iso.x - state.camera_iso.x) * state.zoom + sapp.widthf() * 0.5,
        .y = (iso.y - state.camera_iso.y) * state.zoom + sapp.heightf() * 0.5,
    };
}

fn screenToWorld(screen: Vec2) Vec2 {
    const hw = state.tile_world_w * 0.5;
    const hh = state.tile_world_h * 0.5;
    const iso_x = (screen.x - sapp.widthf() * 0.5) / state.zoom + state.camera_iso.x;
    const iso_y = (screen.y - sapp.heightf() * 0.5) / state.zoom + state.camera_iso.y;
    return .{
        .x = ((iso_y / hh) + (iso_x / hw)) * 0.5,
        .y = ((iso_y / hh) - (iso_x / hw)) * 0.5,
    };
}

fn clampWorld(pos: Vec2) Vec2 {
    return .{
        .x = clamp(pos.x, 0.5, @as(f32, @floatFromInt(MapW)) - 0.5),
        .y = clamp(pos.y, 0.5, @as(f32, @floatFromInt(MapH)) - 0.5),
    };
}

fn activeTileCount() usize {
    return if (state.tile_count == 0) 1 else state.tile_count;
}

fn worldToCell(world: Vec2) ?struct { x: i32, y: i32 } {
    const cx: i32 = @intFromFloat(@floor(world.x));
    const cy: i32 = @intFromFloat(@floor(world.y));
    if (cx < 0 or cx >= MapW or cy < 0 or cy >= MapH) {
        return null;
    }
    return .{ .x = cx, .y = cy };
}

fn setEditorMode(enabled: bool) void {
    state.editor_mode = enabled;
    state.drag = .{};
    state.paint_active = false;
    if (enabled) {
        sapp.setWindowTitle("Zig Isometric RTS [Editor Mode]");
    } else {
        sapp.setWindowTitle("Zig Isometric RTS");
    }
}

fn paintAtWorld(world: Vec2) void {
    const center = worldToCell(world) orelse return;
    const r = state.brush_radius;
    var oy: i32 = -r;
    while (oy <= r) : (oy += 1) {
        var ox: i32 = -r;
        while (ox <= r) : (ox += 1) {
            if (@abs(ox) + @abs(oy) > r) continue;
            const x = center.x + ox;
            const y = center.y + oy;
            if (x < 0 or x >= MapW or y < 0 or y >= MapH) continue;
            state.map[@intCast(y)][@intCast(x)] = state.brush_tile % @as(u8, @intCast(activeTileCount()));
        }
    }
}

fn pickTileAtWorld(world: Vec2) void {
    const cell = worldToCell(world) orelse return;
    state.brush_tile = state.map[@intCast(cell.y)][@intCast(cell.x)] % @as(u8, @intCast(activeTileCount()));
}

fn brushTileFromKey(key: sapp.Keycode) ?u8 {
    return switch (key) {
        ._1 => 0,
        ._2 => 1,
        ._3 => 2,
        ._4 => 3,
        ._5 => 4,
        ._6 => 5,
        ._7 => 6,
        ._8 => 7,
        else => null,
    };
}

fn createSpriteFromPixels(width: i32, height: i32, pixels: []const u8) Sprite {
    const img = sg.makeImage(.{
        .width = width,
        .height = height,
        .pixel_format = .RGBA8,
        .data = .{
            .mip_levels = [_]sg.Range{sg.asRange(pixels)} ++ ([_]sg.Range{.{}} ** 15),
        },
    });
    const view = sg.makeView(.{
        .texture = .{
            .image = img,
        },
    });
    return .{
        .image = img,
        .view = view,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}

fn destroySprite(sprite: *Sprite) void {
    if (sprite.view.id != 0) {
        sg.destroyView(sprite.view);
    }
    if (sprite.image.id != 0) {
        sg.destroyImage(sprite.image);
    }
    sprite.* = .{};
}

fn loadSprite(path: []const u8) !Sprite {
    const image = try png_loader.loadRgba(std.heap.c_allocator, path);
    defer image.deinit();
    _ = applyMagentaKeyToAlpha(image.pixels);
    return createSpriteFromPixels(image.width, image.height, image.pixels);
}

fn appendTileSprite(sprite: Sprite) bool {
    if (!sprite.isValid() or state.tile_count >= TileVariants) {
        return false;
    }
    state.tile_sprites[state.tile_count] = sprite;
    state.tile_count += 1;
    return true;
}

fn appendTileFromPath(path: []const u8) bool {
    if (state.tile_count >= TileVariants) {
        return false;
    }
    if (loadTileSprite(path)) |loaded_sprite| {
        var sprite = loaded_sprite;
        if (appendTileSprite(sprite)) {
            std.log.info("Added tile variant {d}: {s}", .{ state.tile_count, path });
            return true;
        }
        destroySprite(&sprite);
    } else |_| {}
    return false;
}

fn isMagentaKey(r: u8, g: u8, b: u8) bool {
    return r >= 220 and g <= 70 and b >= 220;
}

fn applyMagentaKeyToAlpha(pixels: []u8) usize {
    var changed: usize = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        if (isMagentaKey(pixels[i + 0], pixels[i + 1], pixels[i + 2])) {
            if (pixels[i + 3] != 0) {
                changed += 1;
            }
            pixels[i + 0] = 0;
            pixels[i + 1] = 0;
            pixels[i + 2] = 0;
            pixels[i + 3] = 0;
        }
    }
    return changed;
}

fn parseTileDimsFromPath(path: []const u8) ?struct { w: i32, h: i32 } {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] < '0' or path[i] > '9') continue;

        var j = i;
        while (j < path.len and path[j] >= '0' and path[j] <= '9') : (j += 1) {}
        if (j <= i or j >= path.len or path[j] != 'x') continue;

        var k = j + 1;
        if (k >= path.len or path[k] < '0' or path[k] > '9') continue;
        while (k < path.len and path[k] >= '0' and path[k] <= '9') : (k += 1) {}

        const w = std.fmt.parseInt(i32, path[i..j], 10) catch continue;
        const h = std.fmt.parseInt(i32, path[j + 1 .. k], 10) catch continue;
        if (w > 0 and h > 0) {
            return .{ .w = w, .h = h };
        }
    }
    return null;
}

fn extractBestTile(
    allocator: std.mem.Allocator,
    image: png_loader.LoadedImage,
    tile_w: i32,
    tile_h: i32,
) ![]u8 {
    if (tile_w <= 0 or tile_h <= 0) {
        return allocator.dupe(u8, image.pixels);
    }
    if (image.width < tile_w or image.height < tile_h) {
        return allocator.dupe(u8, image.pixels);
    }

    const cols: i32 = @divFloor(image.width, tile_w);
    const rows: i32 = @divFloor(image.height, tile_h);
    if (cols <= 0 or rows <= 0) {
        return allocator.dupe(u8, image.pixels);
    }

    var best_cx: i32 = 0;
    var best_cy: i32 = 0;
    var best_score: i32 = std.math.minInt(i32);

    var cy: i32 = 0;
    while (cy < rows) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < cols) : (cx += 1) {
            var score: i32 = 0;
            var py: i32 = 0;
            while (py < tile_h) : (py += 1) {
                const sy = cy * tile_h + py;
                var px: i32 = 0;
                while (px < tile_w) : (px += 1) {
                    const sx = cx * tile_w + px;
                    const idx: usize = @intCast((sy * image.width + sx) * 4);
                    const a = image.pixels[idx + 3];
                    if (a > 8) score += 1;
                }
            }
            if (score > best_score) {
                best_score = score;
                best_cx = cx;
                best_cy = cy;
            }
        }
    }

    const out_len: usize = @intCast(tile_w * tile_h * 4);
    const out = try allocator.alloc(u8, out_len);

    var py: i32 = 0;
    while (py < tile_h) : (py += 1) {
        const sy = best_cy * tile_h + py;
        const src_start: usize = @intCast((sy * image.width + best_cx * tile_w) * 4);
        const src_end: usize = src_start + @as(usize, @intCast(tile_w * 4));
        const dst_start: usize = @intCast(py * tile_w * 4);
        @memcpy(out[dst_start .. dst_start + @as(usize, @intCast(tile_w * 4))], image.pixels[src_start..src_end]);
    }

    return out;
}

fn loadTileSprite(path: []const u8) !Sprite {
    const image = try png_loader.loadRgba(std.heap.c_allocator, path);
    defer image.deinit();

    const key_hits = applyMagentaKeyToAlpha(image.pixels);
    if (key_hits > 0) {
        std.log.info("Converted {d} magenta pixels to alpha in {s}", .{ key_hits, path });
    }

    if (parseTileDimsFromPath(path)) |dims| {
        if (image.width > dims.w or image.height > dims.h) {
            const cropped = try extractBestTile(std.heap.c_allocator, image, dims.w, dims.h);
            defer std.heap.c_allocator.free(cropped);
            std.log.info("Extracted tile {d}x{d} from atlas {s}", .{ dims.w, dims.h, path });
            return createSpriteFromPixels(dims.w, dims.h, cropped);
        }
    }

    return createSpriteFromPixels(image.width, image.height, image.pixels);
}

fn loadTileSpriteFromCandidates(candidates: []const []const u8) ?Sprite {
    for (candidates) |path| {
        if (loadTileSprite(path)) |sprite| {
            std.log.info("Loaded tile sprite: {s}", .{path});
            return sprite;
        } else |_| {}
    }
    return null;
}

fn loadSpriteFromCandidates(candidates: []const []const u8) ?Sprite {
    for (candidates) |path| {
        if (loadSprite(path)) |sprite| {
            std.log.info("Loaded sprite: {s}", .{path});
            return sprite;
        } else |_| {}
    }
    return null;
}

const CandidatePath = struct {
    buf: [1024]u8 = [_]u8{0} ** 1024,
    len: usize = 0,
    score: i32 = std.math.minInt(i32),

    fn has(self: @This()) bool {
        return self.len > 0;
    }

    fn slice(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }

    fn consider(self: *@This(), score: i32, full_path: []const u8) void {
        if (score < self.score or full_path.len > self.buf.len) {
            return;
        }
        @memcpy(self.buf[0..full_path.len], full_path);
        self.len = full_path.len;
        self.score = score;
    }
};

const DiscoveredPaths = struct {
    tile: CandidatePath = .{},
    blue: CandidatePath = .{},
    red: CandidatePath = .{},
    unit_any: CandidatePath = .{},
    tile_choices: [32]CandidatePath = [_]CandidatePath{.{}} ** 32,
    tile_choices_count: usize = 0,
};

fn insertTileChoice(out: *DiscoveredPaths, score: i32, full_path: []const u8) void {
    if (score < 20) {
        return;
    }

    var i: usize = 0;
    while (i < out.tile_choices_count) : (i += 1) {
        if (std.mem.eql(u8, out.tile_choices[i].slice(), full_path)) {
            if (score > out.tile_choices[i].score) {
                out.tile_choices[i].consider(score, full_path);
            }
            return;
        }
    }

    if (out.tile_choices_count < out.tile_choices.len) {
        out.tile_choices[out.tile_choices_count].consider(score, full_path);
        out.tile_choices_count += 1;
        return;
    }

    var worst_idx: usize = 0;
    var worst_score = out.tile_choices[0].score;
    i = 1;
    while (i < out.tile_choices.len) : (i += 1) {
        if (out.tile_choices[i].score < worst_score) {
            worst_score = out.tile_choices[i].score;
            worst_idx = i;
        }
    }
    if (score > worst_score) {
        out.tile_choices[worst_idx].consider(score, full_path);
    }
}

fn sortTileChoices(out: *DiscoveredPaths) void {
    var i: usize = 0;
    while (i < out.tile_choices_count) : (i += 1) {
        var best = i;
        var j = i + 1;
        while (j < out.tile_choices_count) : (j += 1) {
            if (out.tile_choices[j].score > out.tile_choices[best].score) {
                best = j;
            }
        }
        if (best != i) {
            const tmp = out.tile_choices[i];
            out.tile_choices[i] = out.tile_choices[best];
            out.tile_choices[best] = tmp;
        }
    }
}

fn hasToken(path: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(path, needle) != null;
}

fn isPngPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".png");
}

fn scoreTilePath(path: []const u8) i32 {
    var score: i32 = 0;
    if (hasToken(path, "ground")) score += 90;
    if (hasToken(path, "tile")) score += 45;
    if (hasToken(path, "grass")) score += 30;
    if (hasToken(path, "floor")) score += 30;
    if (hasToken(path, "dirt")) score += 20;
    if (hasToken(path, "road")) score += 18;
    if (hasToken(path, "path")) score += 14;
    if (hasToken(path, "water")) score -= 10;
    if (hasToken(path, "unit") or hasToken(path, "character") or hasToken(path, "player")) score -= 90;
    if (hasToken(path, "house") or hasToken(path, "roof") or hasToken(path, "wall")) score -= 35;
    return score;
}

fn scoreAnyUnitPath(path: []const u8) i32 {
    var score: i32 = 0;
    if (hasToken(path, "unit")) score += 75;
    if (hasToken(path, "character")) score += 70;
    if (hasToken(path, "hero")) score += 45;
    if (hasToken(path, "player")) score += 35;
    if (hasToken(path, "npc")) score += 25;
    if (hasToken(path, "ground") or hasToken(path, "tile") or hasToken(path, "grass")) score -= 80;
    if (hasToken(path, "tree") or hasToken(path, "house") or hasToken(path, "wall")) score -= 45;
    return score;
}

fn scoreBlueUnitPath(path: []const u8) i32 {
    var score = scoreAnyUnitPath(path);
    if (hasToken(path, "blue")) score += 95;
    if (hasToken(path, "cyan")) score += 24;
    if (hasToken(path, "red")) score -= 80;
    return score;
}

fn scoreRedUnitPath(path: []const u8) i32 {
    var score = scoreAnyUnitPath(path);
    if (hasToken(path, "red")) score += 95;
    if (hasToken(path, "maroon")) score += 20;
    if (hasToken(path, "blue")) score -= 80;
    return score;
}

fn discoverIsoTownPaths() DiscoveredPaths {
    var out: DiscoveredPaths = .{};
    if (builtin.target.cpu.arch.isWasm()) {
        return out;
    }
    const root = assetPath("iso-town-pack");

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        std.log.warn("Auto-discovery skipped for {s}: {s}", .{ root, @errorName(err) });
        return out;
    };
    defer dir.close();

    var walker = dir.walk(std.heap.c_allocator) catch |err| {
        std.log.warn("Failed to walk {s}: {s}", .{ root, @errorName(err) });
        return out;
    };
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next() catch |err| {
            std.log.warn("Asset walk error in {s}: {s}", .{ root, @errorName(err) });
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file or !isPngPath(entry.path)) {
            continue;
        }

        var full_path_buf: [1200]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ root, entry.path }) catch continue;

        const tile_score = scoreTilePath(entry.path);
        out.tile.consider(tile_score, full_path);
        insertTileChoice(&out, tile_score, full_path);
        out.blue.consider(scoreBlueUnitPath(entry.path), full_path);
        out.red.consider(scoreRedUnitPath(entry.path), full_path);
        out.unit_any.consider(scoreAnyUnitPath(entry.path), full_path);
    }

    sortTileChoices(&out);
    return out;
}

fn loadSpriteFromDiscovery(candidate: CandidatePath, min_score: i32) ?Sprite {
    if (!candidate.has() or candidate.score < min_score) {
        return null;
    }

    const path = candidate.slice();
    if (loadSprite(path)) |sprite| {
        std.log.info("Auto-selected sprite: {s} (score {d})", .{ path, candidate.score });
        return sprite;
    } else |err| {
        std.log.warn("Failed loading auto-selected sprite {s}: {s}", .{ path, @errorName(err) });
        return null;
    }
}

fn loadTileSpriteFromDiscovery(candidate: CandidatePath, min_score: i32) ?Sprite {
    if (!candidate.has() or candidate.score < min_score) {
        return null;
    }

    const path = candidate.slice();
    if (loadTileSprite(path)) |sprite| {
        std.log.info("Auto-selected tile sprite: {s} (score {d})", .{ path, candidate.score });
        return sprite;
    } else |err| {
        std.log.warn("Failed loading auto-selected tile sprite {s}: {s}", .{ path, @errorName(err) });
        return null;
    }
}

fn makeFallbackTileSprite() !Sprite {
    const w: i32 = 64;
    const h: i32 = 32;
    const len: usize = @intCast(w * h * 4);
    const pixels = try std.heap.c_allocator.alloc(u8, len);
    defer std.heap.c_allocator.free(pixels);

    @memset(pixels, 0);

    const hw = @as(f32, @floatFromInt(w)) * 0.5;
    const hh = @as(f32, @floatFromInt(h)) * 0.5;
    const cx = hw - 0.5;
    const cy = hh - 0.5;

    var py: i32 = 0;
    while (py < h) : (py += 1) {
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const nx = @abs((@as(f32, @floatFromInt(px)) - cx) / hw);
            const ny = @abs((@as(f32, @floatFromInt(py)) - cy) / hh);
            if (nx + ny <= 1.0) {
                const i: usize = @intCast((py * w + px) * 4);
                const shade = 90 + @as(u8, @intFromFloat((1.0 - (nx + ny)) * 35.0));
                pixels[i + 0] = shade;
                pixels[i + 1] = shade + 20;
                pixels[i + 2] = shade;
                pixels[i + 3] = 255;
            }
        }
    }
    return createSpriteFromPixels(w, h, pixels);
}

fn makeFallbackUnitSprite(team: u8) !Sprite {
    const w: i32 = 40;
    const h: i32 = 56;
    const len: usize = @intCast(w * h * 4);
    const pixels = try std.heap.c_allocator.alloc(u8, len);
    defer std.heap.c_allocator.free(pixels);

    @memset(pixels, 0);

    const base_r: u8 = if (team == 0) 72 else 190;
    const base_g: u8 = if (team == 0) 160 else 74;
    const base_b: u8 = if (team == 0) 220 else 72;

    const cx = @as(f32, @floatFromInt(w)) * 0.5;
    const cy = @as(f32, @floatFromInt(h)) * 0.5;

    var py: i32 = 0;
    while (py < h) : (py += 1) {
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const dx = (@as(f32, @floatFromInt(px)) - cx) / (@as(f32, @floatFromInt(w)) * 0.35);
            const dy = (@as(f32, @floatFromInt(py)) - cy) / (@as(f32, @floatFromInt(h)) * 0.45);
            if ((dx * dx + dy * dy) <= 1.0) {
                const i: usize = @intCast((py * w + px) * 4);
                pixels[i + 0] = base_r;
                pixels[i + 1] = base_g;
                pixels[i + 2] = base_b;
                pixels[i + 3] = 255;
            }
        }
    }

    return createSpriteFromPixels(w, h, pixels);
}

fn clearSelection() void {
    for (state.units[0..state.unit_count]) |*unit| {
        unit.selected = false;
    }
}

fn pickUnitAtWorld(world: Vec2) ?usize {
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

fn selectByClick(mouse: Vec2, additive: bool) void {
    if (!additive) {
        clearSelection();
    }

    if (pickUnitAtWorld(screenToWorld(mouse))) |idx| {
        state.units[idx].selected = true;
    }
}

fn selectByBox(a: Vec2, b: Vec2, additive: bool) void {
    if (!additive) {
        clearSelection();
    }

    const min_x = @min(a.x, b.x);
    const max_x = @max(a.x, b.x);
    const min_y = @min(a.y, b.y);
    const max_y = @max(a.y, b.y);

    var i: usize = 0;
    while (i < state.unit_count) : (i += 1) {
        const p = worldToScreen(state.units[i].pos);
        if (p.x >= min_x and p.x <= max_x and p.y >= min_y and p.y <= max_y) {
            state.units[i].selected = true;
        }
    }
}

fn issueMoveOrder(mouse: Vec2) void {
    var selected: [MaxUnits]usize = undefined;
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

    const target = clampWorld(screenToWorld(mouse));
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

        state.units[selected[i]].target = clampWorld(.{
            .x = target.x + offset_x,
            .y = target.y + offset_y,
        });
    }
}

fn keyIndex(key: sapp.Keycode) ?usize {
    const raw: i32 = @intFromEnum(key);
    if (raw < 0 or raw >= state.keys.len) {
        return null;
    }
    return @intCast(raw);
}

fn isKeyDown(key: sapp.Keycode) bool {
    if (keyIndex(key)) |idx| {
        return state.keys[idx];
    }
    return false;
}

fn update(dt: f32) void {
    const pan_speed = 520.0 / state.zoom;
    if (isKeyDown(.A) or isKeyDown(.LEFT)) {
        state.camera_iso.x -= pan_speed * dt;
    }
    if (isKeyDown(.D) or isKeyDown(.RIGHT)) {
        state.camera_iso.x += pan_speed * dt;
    }
    if (isKeyDown(.W) or isKeyDown(.UP)) {
        state.camera_iso.y -= pan_speed * dt;
    }
    if (isKeyDown(.S) or isKeyDown(.DOWN)) {
        state.camera_iso.y += pan_speed * dt;
    }

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

    if (state.hud_time_left > 0.0) {
        state.hud_time_left = @max(0.0, state.hud_time_left - dt);
    }
}

fn emitQuadCentered(cx: f32, cy: f32, w: f32, h: f32) void {
    const x0 = cx - w * 0.5;
    const y0 = cy - h * 0.5;
    const x1 = x0 + w;
    const y1 = y0 + h;

    sgl.v2fT2f(x0, y0, 0.0, 0.0);
    sgl.v2fT2f(x1, y0, 1.0, 0.0);
    sgl.v2fT2f(x1, y1, 1.0, 1.0);
    sgl.v2fT2f(x0, y1, 0.0, 1.0);
}

fn emitQuadBottom(cx: f32, by: f32, w: f32, h: f32) void {
    const x0 = cx - w * 0.5;
    const y0 = by - h;
    const x1 = x0 + w;
    const y1 = by;

    sgl.v2fT2f(x0, y0, 0.0, 0.0);
    sgl.v2fT2f(x1, y0, 1.0, 0.0);
    sgl.v2fT2f(x1, y1, 1.0, 1.0);
    sgl.v2fT2f(x0, y1, 0.0, 1.0);
}

fn drawMap() void {
    const corners = [_]Vec2{
        screenToWorld(.{ .x = 0, .y = 0 }),
        screenToWorld(.{ .x = sapp.widthf(), .y = 0 }),
        screenToWorld(.{ .x = 0, .y = sapp.heightf() }),
        screenToWorld(.{ .x = sapp.widthf(), .y = sapp.heightf() }),
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

    const start_x = @max(0, @as(i32, @intFromFloat(@floor(min_x))) - 3);
    const end_x = @min(MapW - 1, @as(i32, @intFromFloat(@ceil(max_x))) + 3);
    const start_y = @max(0, @as(i32, @intFromFloat(@floor(min_y))) - 3);
    const end_y = @min(MapH - 1, @as(i32, @intFromFloat(@ceil(max_y))) + 3);

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

        var y: i32 = start_y;
        while (y <= end_y) : (y += 1) {
            var x: i32 = start_x;
            while (x <= end_x) : (x += 1) {
                if (@as(usize, state.map[@intCast(y)][@intCast(x)] % @as(u8, @intCast(activeTileCount()))) != tile_idx) {
                    continue;
                }
                const world = Vec2{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                };
                const screen = worldToScreen(world);
                sgl.c4f(1.0, 1.0, 1.0, 1.0);
                emitQuadCentered(screen.x, screen.y, draw_w, draw_h);
            }
        }

        sgl.end();
    }

    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawUnits() void {
    var order: [MaxUnits]usize = undefined;
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

        const screen = worldToScreen(unit.pos);
        sgl.c4f(1.0, 1.0, 1.0, 1.0);
        emitQuadBottom(screen.x, screen.y, blue_w, blue_h);
    }
    sgl.end();

    sgl.texture(state.unit_red_sprite.view, state.sampler);
    sgl.beginQuads();
    for (order[0..state.unit_count]) |idx| {
        const unit = state.units[idx];
        if (unit.team != 1) continue;

        const screen = worldToScreen(unit.pos);
        sgl.c4f(1.0, 1.0, 1.0, 1.0);
        emitQuadBottom(screen.x, screen.y, red_w, red_h);
    }
    sgl.end();

    sgl.disableTexture();
    sgl.loadDefaultPipeline();

    for (state.units[0..state.unit_count]) |unit| {
        if (!unit.selected) continue;

        const screen = worldToScreen(unit.pos);
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

fn drawSelectionBox() void {
    if (!state.drag.active or !state.drag.box_select) {
        return;
    }

    const a = state.drag.start;
    const b = state.drag.current;
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

fn drawEditorOverlay() void {
    if (!state.editor_mode) {
        return;
    }

    const mouse_world = screenToWorld(state.mouse_screen);
    if (worldToCell(mouse_world)) |center| {
        var oy: i32 = -state.brush_radius;
        while (oy <= state.brush_radius) : (oy += 1) {
            var ox: i32 = -state.brush_radius;
            while (ox <= state.brush_radius) : (ox += 1) {
                if (@abs(ox) + @abs(oy) > state.brush_radius) continue;
                const tx = center.x + ox;
                const ty = center.y + oy;
                if (tx < 0 or tx >= MapW or ty < 0 or ty >= MapH) continue;
                const screen = worldToScreen(.{
                    .x = @as(f32, @floatFromInt(tx)) + 0.5,
                    .y = @as(f32, @floatFromInt(ty)) + 0.5,
                });
                const rx = state.tile_world_w * 0.50 * state.zoom;
                const ry = state.tile_world_h * 0.50 * state.zoom;
                sgl.disableTexture();
                sgl.c4f(0.95, 0.95, 0.95, 0.90);
                sgl.beginLineStrip();
                sgl.v2f(screen.x, screen.y - ry);
                sgl.v2f(screen.x + rx, screen.y);
                sgl.v2f(screen.x, screen.y + ry);
                sgl.v2f(screen.x - rx, screen.y);
                sgl.v2f(screen.x, screen.y - ry);
                sgl.end();
            }
        }
    }

    if (state.tile_count == 0) {
        return;
    }

    const sw = 44.0;
    const sh = 30.0;
    const pad = 6.0;

    sgl.loadPipeline(state.alpha_pipeline);
    sgl.enableTexture();

    var i: usize = 0;
    while (i < state.tile_count) : (i += 1) {
        const x0 = 14.0 + @as(f32, @floatFromInt(i)) * (sw + pad);
        const y0 = 14.0;
        const x1 = x0 + sw;
        const y1 = y0 + sh;

        const sprite = state.tile_sprites[i];
        sgl.texture(sprite.view, state.sampler);
        sgl.c4f(1.0, 1.0, 1.0, 1.0);
        sgl.beginQuads();
        sgl.v2fT2f(x0, y0, 0.0, 0.0);
        sgl.v2fT2f(x1, y0, 1.0, 0.0);
        sgl.v2fT2f(x1, y1, 1.0, 1.0);
        sgl.v2fT2f(x0, y1, 0.0, 1.0);
        sgl.end();

        sgl.disableTexture();
        sgl.loadDefaultPipeline();
        const is_selected = i == state.brush_tile;
        sgl.c4f(if (is_selected) 0.15 else 0.05, if (is_selected) 1.0 else 0.05, if (is_selected) 0.20 else 0.05, 0.95);
        sgl.beginLineStrip();
        sgl.v2f(x0, y0);
        sgl.v2f(x1, y0);
        sgl.v2f(x1, y1);
        sgl.v2f(x0, y1);
        sgl.v2f(x0, y0);
        sgl.end();

        sgl.loadPipeline(state.alpha_pipeline);
        sgl.enableTexture();
    }

    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawHudOverlay() void {
    if (state.hud_time_left <= 0.0 or state.hud_message_len == 0) {
        return;
    }

    const fade = if (state.hud_time_left < 0.35) state.hud_time_left / 0.35 else 1.0;
    const message_px_w = @as(f32, @floatFromInt(state.hud_message_len)) * 8.0;
    const box_y = 12.0;
    const box_w = message_px_w + 16.0;
    const box_h = 22.0;

    const tone: HudPalette = switch (state.hud_tone) {
        .info => .{ .r = 0.28, .g = 0.70, .b = 1.00, .tr = @as(u8, 160), .tg = @as(u8, 220), .tb = @as(u8, 255) },
        .success => .{ .r = 0.18, .g = 0.92, .b = 0.32, .tr = @as(u8, 170), .tg = @as(u8, 255), .tb = @as(u8, 180) },
        .warning => .{ .r = 1.00, .g = 0.78, .b = 0.20, .tr = @as(u8, 255), .tg = @as(u8, 222), .tb = @as(u8, 140) },
        .failure => .{ .r = 1.00, .g = 0.35, .b = 0.35, .tr = @as(u8, 255), .tg = @as(u8, 170), .tb = @as(u8, 170) },
    };

    const x0 = @max(12.0, sapp.widthf() - box_w - 12.0);
    const y0 = box_y;
    const x1 = x0 + box_w;
    const y1 = box_y + box_h;

    sgl.disableTexture();
    sgl.c4f(0.30, 0.30, 0.30, 0.78 * fade);
    sgl.beginQuads();
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();

    sgl.c4f(0.62, 0.62, 0.62, 0.90 * fade);
    sgl.beginLineStrip();
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.v2f(x0, y0);
    sgl.end();
    sgl.draw();

    sdtx.canvas(sapp.widthf(), sapp.heightf());
    sdtx.origin((x0 + 8.0) / 8.0, (box_y + 7.0) / 8.0);
    sdtx.home();
    sdtx.color4b(tone.tr, tone.tg, tone.tb, @intFromFloat(255.0 * fade));
    const message_z: [:0]const u8 = state.hud_message[0..state.hud_message_len :0];
    sdtx.puts(message_z);
    sdtx.draw();
}

fn init() callconv(.c) void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });

    var dtx_desc: sdtx.Desc = .{
        .logger = .{ .func = slog.func },
    };
    dtx_desc.fonts[0] = sdtx.fontCpc();
    dtx_desc.context.max_commands = 512;
    dtx_desc.context.char_buf_size = 4096;
    sdtx.setup(dtx_desc);
    sdtx.font(0);

    var alpha_desc: sg.PipelineDesc = .{};
    alpha_desc.colors[0].blend.enabled = true;
    alpha_desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
    alpha_desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
    alpha_desc.colors[0].blend.src_factor_alpha = .ONE;
    alpha_desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA;
    state.alpha_pipeline = sgl.makePipeline(alpha_desc);

    state.pass_action = .{};
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = 0.08,
            .g = 0.11,
            .b = 0.14,
            .a = 1.0,
        },
    };

    state.sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    const tile_candidates = [_][]const u8{
        assetPath("iso-town-pack/ground.png"),
        assetPath("iso-town-pack/tiles/ground.png"),
        assetPath("iso-town-pack/tile_ground.png"),
        assetPath("iso-town-pack/grass.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Grass/Floor_Grass_01-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Grass/Floor_Grass_02-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Stones/Floor_Stones_01-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Stones/Floor_Stones_02-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Dry/Floor_Dry_01-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Dry/Floor_Dry_02-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Rocky/Floor_Rocky_01-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Rocky/Floor_Rocky_02-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Flora/Floor_Flora_01-256x128.png"),
        assetPath("iso-town-pack/SBS - Isometric Floor Tiles - Large 256x128/Large 256x128/Exterior/Flora/Floor_Flora_02-256x128.png"),
    };
    const blue_candidates = [_][]const u8{
        assetPath("iso-town-pack/unit_blue.png"),
        assetPath("iso-town-pack/units/unit_blue.png"),
        assetPath("iso-town-pack/character_blue.png"),
    };
    const red_candidates = [_][]const u8{
        assetPath("iso-town-pack/unit_red.png"),
        assetPath("iso-town-pack/units/unit_red.png"),
        assetPath("iso-town-pack/character_red.png"),
    };
    const discovered = discoverIsoTownPaths();

    state.tile_count = 0;

    for (tile_candidates) |path| {
        _ = appendTileFromPath(path);
        if (state.tile_count >= TileVariants) break;
    }
    if (state.tile_count == 0) {
        if (discovered.tile.has() and discovered.tile.score >= 20) {
            _ = appendTileFromPath(discovered.tile.slice());
        }
    }
    if (state.tile_count == 0) {
        _ = appendTileSprite(makeFallbackTileSprite() catch .{});
    }

    var ti: usize = 0;
    while (ti < discovered.tile_choices_count and state.tile_count < TileVariants) : (ti += 1) {
        _ = appendTileFromPath(discovered.tile_choices[ti].slice());
    }

    state.unit_blue_sprite = loadSpriteFromCandidates(&blue_candidates) orelse
        loadSpriteFromDiscovery(discovered.blue, 30) orelse
        loadSpriteFromDiscovery(discovered.unit_any, 35) orelse
        makeFallbackUnitSprite(0) catch .{};
    state.unit_red_sprite = loadSpriteFromCandidates(&red_candidates) orelse
        loadSpriteFromDiscovery(discovered.red, 30) orelse
        loadSpriteFromDiscovery(discovered.unit_any, 35) orelse
        makeFallbackUnitSprite(1) catch .{};

    const base_tile = state.tile_sprites[0];
    state.tile_world_w = if (base_tile.width > 0) base_tile.width else 64;
    state.tile_world_h = if (base_tile.height > 0) base_tile.height else 32;

    var y: usize = 0;
    while (y < MapH) : (y += 1) {
        var x: usize = 0;
        while (x < MapW) : (x += 1) {
            state.map[y][x] = @intCast((x * 11 + y * 7) % activeTileCount());
        }
    }
    tryLoadMapFromDisk(false, false);

    var i: usize = 0;
    state.unit_count = 16;
    while (i < state.unit_count) : (i += 1) {
        const gx = 16.0 + @as(f32, @floatFromInt(i % 4)) * 1.3;
        const gy = 16.0 + @as(f32, @floatFromInt(i / 4)) * 1.2;
        state.units[i] = .{
            .pos = .{ .x = gx, .y = gy },
            .target = .{ .x = gx, .y = gy },
            .speed = 2.6,
            .team = if ((i % 2) == 0) 0 else 1,
        };
    }

    state.camera_iso = worldToIso(.{
        .x = @as(f32, @floatFromInt(MapW)) * 0.5,
        .y = @as(f32, @floatFromInt(MapH)) * 0.5,
    });

    state.zoom = 1.0;
    state.brush_tile = 0;
    state.brush_radius = 0;
    setEditorMode(false);
    state.initialized = true;
}

fn frame() callconv(.c) void {
    if (!state.initialized) {
        return;
    }

    var dt: f32 = @floatCast(sapp.frameDuration());
    if (!(dt > 0.0 and dt < 0.35)) {
        dt = 1.0 / 60.0;
    }

    update(dt);

    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });

    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.ortho(0.0, sapp.widthf(), sapp.heightf(), 0.0, -1.0, 1.0);

    sgl.matrixModeModelview();
    sgl.loadIdentity();

    drawMap();
    drawUnits();
    if (!state.editor_mode) {
        drawSelectionBox();
    }
    drawEditorOverlay();

    sgl.draw();
    drawHudOverlay();
    sg.endPass();
    sg.commit();
}

fn cleanup() callconv(.c) void {
    if (!state.initialized) {
        return;
    }

    var i: usize = 0;
    while (i < state.tile_count) : (i += 1) {
        destroySprite(&state.tile_sprites[i]);
    }
    destroySprite(&state.unit_blue_sprite);
    destroySprite(&state.unit_red_sprite);

    if (state.sampler.id != 0) {
        sg.destroySampler(state.sampler);
    }
    if (state.alpha_pipeline.id != 0) {
        sgl.destroyPipeline(state.alpha_pipeline);
    }

    sdtx.shutdown();
    sgl.shutdown();
    sg.shutdown();
    state = .{};
}

fn event(ev: [*c]const sapp.Event) callconv(.c) void {
    const e = ev[0];
    state.mouse_screen = .{ .x = e.mouse_x, .y = e.mouse_y };

    switch (e.type) {
        .KEY_DOWN => {
            if (keyIndex(e.key_code)) |idx| {
                state.keys[idx] = true;
            }
            if (e.key_code == .TAB) {
                setEditorMode(!state.editor_mode);
            }
            if (state.editor_mode) {
                const modifiers: u32 = @intCast(e.modifiers);
                if (hasCommandModifier(modifiers) and e.key_code == .S) {
                    saveMapToDisk() catch |err| {
                        std.log.warn("Failed saving map to {s}: {s}", .{ MapSavePath, @errorName(err) });
                        setHudMessage(.failure, HudMessageSeconds, "Save failed: {s}", .{@errorName(err)});
                        return;
                    };
                    std.log.info("Saved map layout to {s}", .{MapSavePath});
                    setHudMessage(.success, HudMessageSeconds, "Saved map v{d}", .{MapFormatVersionCurrent});
                    return;
                }
                if (hasCommandModifier(modifiers) and e.key_code == .L) {
                    tryLoadMapFromDisk(true, true);
                    return;
                }
                if (brushTileFromKey(e.key_code)) |tile| {
                    if (@as(usize, tile) < state.tile_count) {
                        state.brush_tile = tile;
                    }
                }
                if (e.key_code == .LEFT_BRACKET) {
                    state.brush_radius = @max(0, state.brush_radius - 1);
                }
                if (e.key_code == .RIGHT_BRACKET) {
                    state.brush_radius = @min(4, state.brush_radius + 1);
                }
            }
        },
        .KEY_UP => {
            if (keyIndex(e.key_code)) |idx| {
                state.keys[idx] = false;
            }
        },
        .MOUSE_DOWN => {
            if (state.editor_mode and e.mouse_button == .LEFT) {
                state.paint_active = true;
                paintAtWorld(screenToWorld(state.mouse_screen));
            } else if (state.editor_mode and e.mouse_button == .RIGHT) {
                pickTileAtWorld(screenToWorld(state.mouse_screen));
            } else if (e.mouse_button == .LEFT) {
                state.drag.active = true;
                state.drag.box_select = false;
                state.drag.start = state.mouse_screen;
                state.drag.current = state.mouse_screen;
            } else if (e.mouse_button == .RIGHT) {
                issueMoveOrder(state.mouse_screen);
            }
        },
        .MOUSE_MOVE => {
            if (state.editor_mode and state.paint_active) {
                paintAtWorld(screenToWorld(state.mouse_screen));
            } else if (state.drag.active) {
                state.drag.current = state.mouse_screen;
                const dx = state.drag.current.x - state.drag.start.x;
                const dy = state.drag.current.y - state.drag.start.y;
                state.drag.box_select = dx * dx + dy * dy > 10.0 * 10.0;
            }
        },
        .MOUSE_UP => {
            if (state.editor_mode and e.mouse_button == .LEFT) {
                state.paint_active = false;
            } else if (e.mouse_button == .LEFT and state.drag.active) {
                const additive = (e.modifiers & sapp.modifier_shift) != 0;
                if (state.drag.box_select) {
                    selectByBox(state.drag.start, state.drag.current, additive);
                } else {
                    selectByClick(state.mouse_screen, additive);
                }
                state.drag = .{};
            }
        },
        .MOUSE_SCROLL => {
            const before = screenToWorld(state.mouse_screen);
            state.zoom = clamp(state.zoom * (1.0 + e.scroll_y * 0.1), 0.35, 2.5);
            const after = screenToWorld(state.mouse_screen);
            const before_iso = worldToIso(before);
            const after_iso = worldToIso(after);
            state.camera_iso.x += before_iso.x - after_iso.x;
            state.camera_iso.y += before_iso.y - after_iso.y;
        },
        else => {},
    }
}

fn appDesc() sapp.Desc {
    const is_web = builtin.target.cpu.arch.isWasm();
    return .{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 1280,
        .height = 720,
        .sample_count = 4,
        .window_title = "Zig Isometric RTS",
        .icon = .{ .sokol_default = true },
        .html5 = .{
            .canvas_selector = "#canvas",
            .canvas_resize = false,
            .preserve_drawing_buffer = false,
            .premultiplied_alpha = true,
            .ask_leave_site = false,
        },
        .high_dpi = !is_web,
        .logger = .{ .func = slog.func },
    };
}

pub fn main() void {
    sapp.run(appDesc());
}
