const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;

pub const MapW = 48;
pub const MapH = 48;
pub const MaxUnits = 48;
pub const TileVariants = 8;
pub const StructureVariants = 8;
pub const EmptyFloorTile: u8 = 255;
pub const MapSavePath = "assets/map_layout.bin";
pub const MapSaveMagic = [_]u8{ 'T', 'L', 'T', 'N' };
pub const MapFormatVersionCurrent: u16 = 4;
pub const MapFormatVersionV3: u16 = 3;
pub const MapFormatVersionV2: u16 = 2;
pub const MapFormatVersionV1: u16 = 1;
pub const HudMessageSeconds: f32 = 2.6;

pub const HudTone = enum {
    info,
    success,
    warning,
    failure,
};

pub const HudPalette = struct {
    r: f32,
    g: f32,
    b: f32,
    tr: u8,
    tg: u8,
    tb: u8,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const Sprite = struct {
    image: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,

    pub fn isValid(self: Sprite) bool {
        return self.image.id != 0 and self.view.id != 0;
    }
};

pub const Unit = struct {
    pos: Vec2,
    target: Vec2,
    speed: f32,
    team: u8,
    selected: bool = false,
};

pub const DragState = struct {
    active: bool = false,
    box_select: bool = false,
    start: Vec2 = .{ .x = 0, .y = 0 },
    current: Vec2 = .{ .x = 0, .y = 0 },
};

pub const EditorLayer = enum {
    floor,
    wall,
    roof,
};

pub const GameState = struct {
    pass_action: sg.PassAction = .{},
    keys: [512]bool = [_]bool{false} ** 512,

    tile_world_w: f32 = 64,
    tile_world_h: f32 = 32,

    camera_iso: Vec2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,
    mouse_screen: Vec2 = .{ .x = 0, .y = 0 },
    drag: DragState = .{},
    paint_active: bool = false,
    paint_erase: bool = false,
    editor_mode: bool = false,
    editor_layer: EditorLayer = .floor,
    editor_erase_mode: bool = false,
    brush_floor_tile: u8 = 0,
    brush_wall_tile: u8 = 1,
    brush_roof_tile: u8 = 1,
    brush_wall_rot: u8 = 0,
    brush_roof_rot: u8 = 0,
    brush_radius: i32 = 0,

    sampler: sg.Sampler = .{},
    alpha_pipeline: sgl.Pipeline = .{},
    crt_vertex_buffer: sg.Buffer = .{},
    crt_shader: sg.Shader = .{},
    crt_pipeline: sg.Pipeline = .{},
    crt_enabled: bool = true,
    dither_vertex_buffer: sg.Buffer = .{},
    dither_shader: sg.Shader = .{},
    dither_pipeline: sg.Pipeline = .{},
    dither_enabled: bool = true,
    dither_scene_msaa_image: sg.Image = .{},
    dither_scene_resolve_image: sg.Image = .{},
    dither_scene_depth_image: sg.Image = .{},
    dither_scene_msaa_view: sg.View = .{},
    dither_scene_resolve_view: sg.View = .{},
    dither_scene_depth_view: sg.View = .{},
    dither_scene_texture_view: sg.View = .{},
    dither_target_w: i32 = 0,
    dither_target_h: i32 = 0,
    dither_target_sample_count: i32 = 0,
    tile_sprites: [TileVariants]Sprite = [_]Sprite{.{}} ** TileVariants,
    tile_count: usize = 0,
    wall_sprites: [StructureVariants]Sprite = [_]Sprite{.{}} ** StructureVariants,
    wall_count: usize = 0,
    roof_sprites: [StructureVariants]Sprite = [_]Sprite{.{}} ** StructureVariants,
    roof_count: usize = 0,
    unit_blue_sprite: Sprite = .{},
    unit_red_sprite: Sprite = .{},

    map_floor: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    map_wall: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    map_roof: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    map_wall_rot: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    map_roof_rot: [MapH][MapW]u8 = [_][MapW]u8{[_]u8{0} ** MapW} ** MapH,
    units: [MaxUnits]Unit = undefined,
    unit_count: usize = 0,

    hud_tone: HudTone = .info,
    hud_message: [160]u8 = [_]u8{0} ** 160,
    hud_message_len: usize = 0,
    hud_time_left: f32 = 0.0,

    initialized: bool = false,
};
