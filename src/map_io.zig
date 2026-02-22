const std = @import("std");
const t = @import("types.zig");

pub const MapBuffers = struct {
    floor: *[t.MapH][t.MapW]u8,
    wall: *[t.MapH][t.MapW]u8,
    roof: *[t.MapH][t.MapW]u8,
    wall_rot: *[t.MapH][t.MapW]u8,
    roof_rot: *[t.MapH][t.MapW]u8,
};

pub const LoadStatus = enum {
    ok,
    not_found,
    io_error,
    invalid_magic,
    unsupported_size,
    unsupported_version,
    dimension_mismatch,
    truncated,
};

pub const LoadResult = struct {
    status: LoadStatus,
    version: u16 = 0,
    migrated: bool = false,
    io_error: ?anyerror = null,
    expected_size: u64 = 0,
    actual_size: u64 = 0,
    read_w: u16 = 0,
    read_h: u16 = 0,
};

fn mapCellCount() usize {
    return t.MapW * t.MapH;
}

fn mapPayloadLenForVersion(version: u16) usize {
    return switch (version) {
        t.MapFormatVersionV1, t.MapFormatVersionV2 => mapCellCount(),
        t.MapFormatVersionV3 => mapCellCount() * 3,
        t.MapFormatVersionCurrent => mapCellCount() * 5,
        else => 0,
    };
}

pub fn mapFileSizeForVersion(version: u16) u64 {
    return switch (version) {
        t.MapFormatVersionV1 => t.MapSaveMagic.len + 4 + mapPayloadLenForVersion(version),
        else => t.MapSaveMagic.len + 2 + 4 + mapPayloadLenForVersion(version),
    };
}

fn mapFileV1Size() u64 {
    return mapFileSizeForVersion(t.MapFormatVersionV1);
}

fn mapFileV2Size() u64 {
    return mapFileSizeForVersion(t.MapFormatVersionV2);
}

fn mapFileV3Size() u64 {
    return mapFileSizeForVersion(t.MapFormatVersionV3);
}

fn mapFileCurrentSize() u64 {
    return mapFileSizeForVersion(t.MapFormatVersionCurrent);
}

fn readExact(file: *std.fs.File, dst: []u8) !void {
    const read_len = try file.readAll(dst);
    if (read_len != dst.len) {
        return error.UnexpectedEof;
    }
}

pub fn save(path: []const u8, buffers: MapBuffers) !void {
    const floor_bytes = std.mem.asBytes(buffers.floor);
    const wall_bytes = std.mem.asBytes(buffers.wall);
    const roof_bytes = std.mem.asBytes(buffers.roof);
    const wall_rot_bytes = std.mem.asBytes(buffers.wall_rot);
    const roof_rot_bytes = std.mem.asBytes(buffers.roof_rot);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(&t.MapSaveMagic);

    var version_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, version_bytes[0..2], t.MapFormatVersionCurrent, .little);
    try file.writeAll(&version_bytes);

    var dims: [4]u8 = undefined;
    std.mem.writeInt(u16, dims[0..2], @as(u16, t.MapW), .little);
    std.mem.writeInt(u16, dims[2..4], @as(u16, t.MapH), .little);
    try file.writeAll(&dims);

    try file.writeAll(floor_bytes);
    try file.writeAll(wall_bytes);
    try file.writeAll(roof_bytes);
    try file.writeAll(wall_rot_bytes);
    try file.writeAll(roof_rot_bytes);
}

pub fn load(path: []const u8, buffers: MapBuffers) LoadResult {
    const floor_bytes = std.mem.asBytes(buffers.floor);
    const wall_bytes = std.mem.asBytes(buffers.wall);
    const roof_bytes = std.mem.asBytes(buffers.roof);
    const wall_rot_bytes = std.mem.asBytes(buffers.wall_rot);
    const roof_rot_bytes = std.mem.asBytes(buffers.roof_rot);

    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => .{ .status = .not_found },
            else => .{ .status = .io_error, .io_error = err },
        };
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        return .{ .status = .io_error, .io_error = err };
    };

    var magic: [t.MapSaveMagic.len]u8 = undefined;
    readExact(&file, &magic) catch return .{ .status = .truncated };
    if (!std.mem.eql(u8, &magic, &t.MapSaveMagic)) {
        return .{ .status = .invalid_magic };
    }

    var loaded_version: u16 = 0;
    if (stat.size == mapFileV1Size()) {
        loaded_version = t.MapFormatVersionV1;
    } else if (stat.size == mapFileV2Size() or stat.size == mapFileV3Size() or stat.size == mapFileCurrentSize()) {
        var version_bytes: [2]u8 = undefined;
        readExact(&file, &version_bytes) catch return .{ .status = .truncated };
        loaded_version = std.mem.readInt(u16, version_bytes[0..2], .little);
    } else {
        return .{ .status = .unsupported_size, .actual_size = stat.size };
    }

    if (loaded_version == 0 or loaded_version > t.MapFormatVersionCurrent) {
        return .{ .status = .unsupported_version, .version = loaded_version };
    }

    const expected_size = mapFileSizeForVersion(loaded_version);
    if (stat.size != expected_size) {
        return .{
            .status = .unsupported_size,
            .version = loaded_version,
            .expected_size = expected_size,
            .actual_size = stat.size,
        };
    }

    var dims: [4]u8 = undefined;
    readExact(&file, &dims) catch return .{ .status = .truncated, .version = loaded_version };
    const w = std.mem.readInt(u16, dims[0..2], .little);
    const h = std.mem.readInt(u16, dims[2..4], .little);
    if (w != t.MapW or h != t.MapH) {
        return .{ .status = .dimension_mismatch, .version = loaded_version, .read_w = w, .read_h = h };
    }

    if (loaded_version == t.MapFormatVersionV1 or loaded_version == t.MapFormatVersionV2) {
        readExact(&file, floor_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        @memset(wall_bytes, 0);
        @memset(roof_bytes, 0);
        @memset(wall_rot_bytes, 0);
        @memset(roof_rot_bytes, 0);
    } else if (loaded_version == t.MapFormatVersionV3) {
        readExact(&file, floor_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, wall_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, roof_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        @memset(wall_rot_bytes, 0);
        @memset(roof_rot_bytes, 0);
    } else {
        readExact(&file, floor_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, wall_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, roof_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, wall_rot_bytes) catch return .{ .status = .truncated, .version = loaded_version };
        readExact(&file, roof_rot_bytes) catch return .{ .status = .truncated, .version = loaded_version };
    }

    if (loaded_version < t.MapFormatVersionCurrent) {
        save(path, buffers) catch |err| {
            return .{ .status = .io_error, .version = loaded_version, .io_error = err };
        };
        return .{ .status = .ok, .version = loaded_version, .migrated = true };
    }

    return .{ .status = .ok, .version = loaded_version };
}
