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
const t = @import("types.zig");
const map_io = @import("map_io.zig");
const units_sys = @import("units.zig");
const editor_sys = @import("editor.zig");
const render_sys = @import("render.zig");
const MapW = t.MapW;
const MapH = t.MapH;
const MaxUnits = t.MaxUnits;
const TileVariants = t.TileVariants;
const StructureVariants = t.StructureVariants;
const EmptyFloorTile = t.EmptyFloorTile;
const MapSavePath = t.MapSavePath;
const MapSaveMagic = t.MapSaveMagic;
const MapFormatVersionCurrent = t.MapFormatVersionCurrent;
const MapFormatVersionV3 = t.MapFormatVersionV3;
const MapFormatVersionV2 = t.MapFormatVersionV2;
const MapFormatVersionV1 = t.MapFormatVersionV1;
const HudMessageSeconds = t.HudMessageSeconds;
const HudTone = t.HudTone;
const HudPalette = t.HudPalette;
const Vec2 = t.Vec2;
const Sprite = t.Sprite;
const Unit = t.Unit;
const DragState = t.DragState;
const EditorLayer = t.EditorLayer;
const GameState = t.GameState;

var state: GameState = .{};

const crt_vs_glsl =
    \\#version 330
    \\layout(location=0) in vec2 position;
    \\out vec2 uv;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = position * 0.5 + 0.5;
    \\}
;

const crt_fs_glsl =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 frag_color;
    \\
    \\void main() {
    \\    vec2 centered = uv * 2.0 - 1.0;
    \\    float scan = 0.5 + 0.5 * sin(gl_FragCoord.y * 3.14159265);
    \\    float grille = 0.5 + 0.5 * sin(gl_FragCoord.x * 2.09439510);
    \\    float edge = dot(centered * vec2(0.82, 1.05), centered * vec2(0.82, 1.05));
    \\    float vignette = 1.0 - clamp(edge, 0.0, 1.0);
    \\    float darken = (1.0 - scan) * 0.24 + (1.0 - grille) * 0.16 + (1.0 - vignette) * 0.24;
    \\    float alpha = clamp(0.05 + darken, 0.0, 0.70);
    \\    frag_color = vec4(0.02, 0.05, 0.02, alpha);
    \\}
;

const crt_vs_gles3 =
    \\#version 300 es
    \\precision mediump float;
    \\layout(location=0) in vec2 position;
    \\out vec2 uv;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = position * 0.5 + 0.5;
    \\}
;

const crt_fs_gles3 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 uv;
    \\out vec4 frag_color;
    \\
    \\void main() {
    \\    vec2 centered = uv * 2.0 - 1.0;
    \\    float scan = 0.5 + 0.5 * sin(gl_FragCoord.y * 3.14159265);
    \\    float grille = 0.5 + 0.5 * sin(gl_FragCoord.x * 2.09439510);
    \\    float edge = dot(centered * vec2(0.82, 1.05), centered * vec2(0.82, 1.05));
    \\    float vignette = 1.0 - clamp(edge, 0.0, 1.0);
    \\    float darken = (1.0 - scan) * 0.24 + (1.0 - grille) * 0.16 + (1.0 - vignette) * 0.24;
    \\    float alpha = clamp(0.05 + darken, 0.0, 0.70);
    \\    frag_color = vec4(0.02, 0.05, 0.02, alpha);
    \\}
;

const crt_src_hlsl =
    \\struct VSIn {
    \\    float2 position : POSITION;
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv : TEXCOORD0;
    \\};
    \\
    \\VSOut vs_main(VSIn in_vert) {
    \\    VSOut outp;
    \\    outp.pos = float4(in_vert.position, 0.0, 1.0);
    \\    outp.uv = in_vert.position * 0.5 + 0.5;
    \\    return outp;
    \\}
    \\
    \\float4 fs_main(VSOut in_frag) : SV_Target0 {
    \\    float2 centered = in_frag.uv * 2.0 - 1.0;
    \\    float scan = 0.5 + 0.5 * sin(in_frag.pos.y * 3.14159265);
    \\    float grille = 0.5 + 0.5 * sin(in_frag.pos.x * 2.09439510);
    \\    float edge = dot(centered * float2(0.82, 1.05), centered * float2(0.82, 1.05));
    \\    float vignette = 1.0 - clamp(edge, 0.0, 1.0);
    \\    float darken = (1.0 - scan) * 0.24 + (1.0 - grille) * 0.16 + (1.0 - vignette) * 0.24;
    \\    float alpha = clamp(0.05 + darken, 0.0, 0.70);
    \\    return float4(0.02, 0.05, 0.02, alpha);
    \\}
;

const crt_src_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VSIn {
    \\    float2 position [[attribute(0)]];
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos [[position]];
    \\    float2 uv;
    \\};
    \\
    \\vertex VSOut vs_main(VSIn in_vert [[stage_in]]) {
    \\    VSOut outp;
    \\    outp.pos = float4(in_vert.position, 0.0, 1.0);
    \\    outp.uv = in_vert.position * 0.5 + 0.5;
    \\    return outp;
    \\}
    \\
    \\fragment float4 fs_main(VSOut in_frag [[stage_in]]) {
    \\    float2 centered = in_frag.uv * 2.0 - 1.0;
    \\    float scan = 0.5 + 0.5 * sin(in_frag.pos.y * 3.14159265);
    \\    float grille = 0.5 + 0.5 * sin(in_frag.pos.x * 2.09439510);
    \\    float edge = dot(centered * float2(0.82, 1.05), centered * float2(0.82, 1.05));
    \\    float vignette = 1.0 - clamp(edge, 0.0, 1.0);
    \\    float darken = (1.0 - scan) * 0.24 + (1.0 - grille) * 0.16 + (1.0 - vignette) * 0.24;
    \\    float alpha = clamp(0.05 + darken, 0.0, 0.70);
    \\    return float4(0.02, 0.05, 0.02, alpha);
    \\}
;

const dither_vs_glsl =
    \\#version 330
    \\layout(location=0) in vec2 position;
    \\out vec2 uv;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = position * 0.5 + 0.5;
    \\}
;

const dither_fs_glsl =
    \\#version 330
    \\uniform sampler2D scene_tex;
    \\in vec2 uv;
    \\out vec4 frag_color;
    \\
    \\float bwThreshold4x4(vec2 frag_xy) {
    \\    int x = int(frag_xy.x) & 3;
    \\    int y = int(frag_xy.y) & 3;
    \\    float t = 0.0;
    \\    if (y == 0) {
    \\        if (x == 0) t = 0.0;
    \\        else if (x == 1) t = 8.0;
    \\        else if (x == 2) t = 2.0;
    \\        else t = 10.0;
    \\    } else if (y == 1) {
    \\        if (x == 0) t = 12.0;
    \\        else if (x == 1) t = 4.0;
    \\        else if (x == 2) t = 14.0;
    \\        else t = 6.0;
    \\    } else if (y == 2) {
    \\        if (x == 0) t = 3.0;
    \\        else if (x == 1) t = 11.0;
    \\        else if (x == 2) t = 1.0;
    \\        else t = 9.0;
    \\    } else {
    \\        if (x == 0) t = 15.0;
    \\        else if (x == 1) t = 7.0;
    \\        else if (x == 2) t = 13.0;
    \\        else t = 5.0;
    \\    }
    \\    return (t + 0.5) / 16.0;
    \\}
    \\
    \\void main() {
    \\    vec4 src = texture(scene_tex, uv);
    \\    float luma = dot(src.rgb, vec3(0.299, 0.587, 0.114));
    \\    float threshold = bwThreshold4x4(gl_FragCoord.xy);
    \\    float bw = step(threshold, luma);
    \\    frag_color = vec4(vec3(bw), src.a);
    \\}
;

const dither_vs_gles3 =
    \\#version 300 es
    \\precision highp float;
    \\layout(location=0) in vec2 position;
    \\out vec2 uv;
    \\
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    uv = position * 0.5 + 0.5;
    \\}
;

const dither_fs_gles3 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D scene_tex;
    \\in vec2 uv;
    \\out vec4 frag_color;
    \\
    \\float bwThreshold4x4(vec2 frag_xy) {
    \\    int x = int(frag_xy.x) & 3;
    \\    int y = int(frag_xy.y) & 3;
    \\    float t = 0.0;
    \\    if (y == 0) {
    \\        if (x == 0) t = 0.0;
    \\        else if (x == 1) t = 8.0;
    \\        else if (x == 2) t = 2.0;
    \\        else t = 10.0;
    \\    } else if (y == 1) {
    \\        if (x == 0) t = 12.0;
    \\        else if (x == 1) t = 4.0;
    \\        else if (x == 2) t = 14.0;
    \\        else t = 6.0;
    \\    } else if (y == 2) {
    \\        if (x == 0) t = 3.0;
    \\        else if (x == 1) t = 11.0;
    \\        else if (x == 2) t = 1.0;
    \\        else t = 9.0;
    \\    } else {
    \\        if (x == 0) t = 15.0;
    \\        else if (x == 1) t = 7.0;
    \\        else if (x == 2) t = 13.0;
    \\        else t = 5.0;
    \\    }
    \\    return (t + 0.5) / 16.0;
    \\}
    \\
    \\void main() {
    \\    vec4 src = texture(scene_tex, uv);
    \\    float luma = dot(src.rgb, vec3(0.299, 0.587, 0.114));
    \\    float threshold = bwThreshold4x4(gl_FragCoord.xy);
    \\    float bw = step(threshold, luma);
    \\    frag_color = vec4(vec3(bw), src.a);
    \\}
;

const dither_src_hlsl =
    \\Texture2D scene_tex : register(t0);
    \\SamplerState scene_smp : register(s0);
    \\
    \\struct VSIn {
    \\    float2 position : POSITION;
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv : TEXCOORD0;
    \\};
    \\
    \\VSOut vs_main(VSIn in_vert) {
    \\    VSOut outp;
    \\    outp.pos = float4(in_vert.position, 0.0, 1.0);
    \\    outp.uv = in_vert.position * 0.5 + 0.5;
    \\    return outp;
    \\}
    \\
    \\float bwThreshold4x4(float2 frag_xy) {
    \\    int x = ((int)frag_xy.x) & 3;
    \\    int y = ((int)frag_xy.y) & 3;
    \\    float t = 0.0;
    \\    if (y == 0) {
    \\        if (x == 0) t = 0.0;
    \\        else if (x == 1) t = 8.0;
    \\        else if (x == 2) t = 2.0;
    \\        else t = 10.0;
    \\    } else if (y == 1) {
    \\        if (x == 0) t = 12.0;
    \\        else if (x == 1) t = 4.0;
    \\        else if (x == 2) t = 14.0;
    \\        else t = 6.0;
    \\    } else if (y == 2) {
    \\        if (x == 0) t = 3.0;
    \\        else if (x == 1) t = 11.0;
    \\        else if (x == 2) t = 1.0;
    \\        else t = 9.0;
    \\    } else {
    \\        if (x == 0) t = 15.0;
    \\        else if (x == 1) t = 7.0;
    \\        else if (x == 2) t = 13.0;
    \\        else t = 5.0;
    \\    }
    \\    return (t + 0.5) / 16.0;
    \\}
    \\
    \\float4 fs_main(VSOut in_frag) : SV_Target0 {
    \\    float4 src = scene_tex.Sample(scene_smp, in_frag.uv);
    \\    float luma = dot(src.rgb, float3(0.299, 0.587, 0.114));
    \\    float threshold = bwThreshold4x4(in_frag.pos.xy);
    \\    float bw = (luma >= threshold) ? 1.0 : 0.0;
    \\    return float4(bw, bw, bw, src.a);
    \\}
;

const dither_src_metal =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VSIn {
    \\    float2 position [[attribute(0)]];
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos [[position]];
    \\    float2 uv;
    \\};
    \\
    \\vertex VSOut vs_main(VSIn in_vert [[stage_in]]) {
    \\    VSOut outp;
    \\    outp.pos = float4(in_vert.position, 0.0, 1.0);
    \\    outp.uv = in_vert.position * 0.5 + 0.5;
    \\    return outp;
    \\}
    \\
    \\float bwThreshold4x4(float2 frag_xy) {
    \\    int x = int(frag_xy.x) & 3;
    \\    int y = int(frag_xy.y) & 3;
    \\    float t = 0.0;
    \\    if (y == 0) {
    \\        if (x == 0) t = 0.0;
    \\        else if (x == 1) t = 8.0;
    \\        else if (x == 2) t = 2.0;
    \\        else t = 10.0;
    \\    } else if (y == 1) {
    \\        if (x == 0) t = 12.0;
    \\        else if (x == 1) t = 4.0;
    \\        else if (x == 2) t = 14.0;
    \\        else t = 6.0;
    \\    } else if (y == 2) {
    \\        if (x == 0) t = 3.0;
    \\        else if (x == 1) t = 11.0;
    \\        else if (x == 2) t = 1.0;
    \\        else t = 9.0;
    \\    } else {
    \\        if (x == 0) t = 15.0;
    \\        else if (x == 1) t = 7.0;
    \\        else if (x == 2) t = 13.0;
    \\        else t = 5.0;
    \\    }
    \\    return (t + 0.5) / 16.0;
    \\}
    \\
    \\fragment float4 fs_main(
    \\    VSOut in_frag [[stage_in]],
    \\    texture2d<float> scene_tex [[texture(0)]],
    \\    sampler scene_smp [[sampler(0)]]
    \\) {
    \\    float4 src = scene_tex.sample(scene_smp, in_frag.uv);
    \\    float luma = dot(src.rgb, float3(0.299, 0.587, 0.114));
    \\    float threshold = bwThreshold4x4(in_frag.pos.xy);
    \\    float bw = luma >= threshold ? 1.0 : 0.0;
    \\    return float4(bw, bw, bw, src.a);
    \\}
;

fn makeCrtShader(backend: sg.Backend) ?sg.Shader {
    var desc: sg.ShaderDesc = .{};
    desc.attrs[0].base_type = .FLOAT;
    desc.attrs[0].glsl_name = "position";
    desc.attrs[0].hlsl_sem_name = "POSITION";
    desc.attrs[0].hlsl_sem_index = 0;

    switch (backend) {
        .GLCORE => {
            desc.vertex_func.source = crt_vs_glsl.ptr;
            desc.fragment_func.source = crt_fs_glsl.ptr;
        },
        .GLES3 => {
            desc.vertex_func.source = crt_vs_gles3.ptr;
            desc.fragment_func.source = crt_fs_gles3.ptr;
        },
        .D3D11 => {
            desc.vertex_func.source = crt_src_hlsl.ptr;
            desc.vertex_func.entry = "vs_main";
            desc.fragment_func.source = crt_src_hlsl.ptr;
            desc.fragment_func.entry = "fs_main";
        },
        .METAL_IOS, .METAL_MACOS, .METAL_SIMULATOR => {
            desc.vertex_func.source = crt_src_metal.ptr;
            desc.vertex_func.entry = "vs_main";
            desc.fragment_func.source = crt_src_metal.ptr;
            desc.fragment_func.entry = "fs_main";
        },
        else => return null,
    }

    const shader = sg.makeShader(desc);
    if (shader.id == 0) {
        return null;
    }
    return shader;
}

fn makeDitherShader(backend: sg.Backend) ?sg.Shader {
    var desc: sg.ShaderDesc = .{};
    desc.attrs[0].base_type = .FLOAT;
    desc.attrs[0].glsl_name = "position";
    desc.attrs[0].hlsl_sem_name = "POSITION";
    desc.attrs[0].hlsl_sem_index = 0;

    desc.views[0].texture.stage = .FRAGMENT;
    desc.views[0].texture.image_type = ._2D;
    desc.views[0].texture.sample_type = .FLOAT;
    desc.samplers[0].stage = .FRAGMENT;
    desc.samplers[0].sampler_type = .FILTERING;
    desc.texture_sampler_pairs[0].stage = .FRAGMENT;
    desc.texture_sampler_pairs[0].view_slot = 0;
    desc.texture_sampler_pairs[0].sampler_slot = 0;
    desc.texture_sampler_pairs[0].glsl_name = "scene_tex";

    switch (backend) {
        .GLCORE => {
            desc.vertex_func.source = dither_vs_glsl.ptr;
            desc.fragment_func.source = dither_fs_glsl.ptr;
        },
        .GLES3 => {
            desc.vertex_func.source = dither_vs_gles3.ptr;
            desc.fragment_func.source = dither_fs_gles3.ptr;
        },
        .D3D11 => {
            desc.vertex_func.source = dither_src_hlsl.ptr;
            desc.vertex_func.entry = "vs_main";
            desc.fragment_func.source = dither_src_hlsl.ptr;
            desc.fragment_func.entry = "fs_main";
            desc.views[0].texture.hlsl_register_t_n = 0;
            desc.samplers[0].hlsl_register_s_n = 0;
        },
        .METAL_IOS, .METAL_MACOS, .METAL_SIMULATOR => {
            desc.vertex_func.source = dither_src_metal.ptr;
            desc.vertex_func.entry = "vs_main";
            desc.fragment_func.source = dither_src_metal.ptr;
            desc.fragment_func.entry = "fs_main";
            desc.views[0].texture.msl_texture_n = 0;
            desc.samplers[0].msl_sampler_n = 0;
        },
        else => return null,
    }

    const shader = sg.makeShader(desc);
    if (shader.id == 0) {
        return null;
    }
    return shader;
}

fn initCrtPipeline() void {
    const crt_vertices = [_]f32{
        -1.0, -1.0,
        3.0,  -1.0,
        -1.0, 3.0,
    };
    state.crt_vertex_buffer = sg.makeBuffer(.{
        .usage = .{
            .vertex_buffer = true,
            .immutable = true,
        },
        .data = sg.asRange(&crt_vertices),
    });
    if (state.crt_vertex_buffer.id == 0) {
        state.crt_enabled = false;
        std.log.warn("CRT filter disabled: fullscreen triangle buffer creation failed", .{});
        return;
    }

    const backend = sg.queryBackend();
    state.crt_shader = makeCrtShader(backend) orelse {
        sg.destroyBuffer(state.crt_vertex_buffer);
        state.crt_vertex_buffer = .{};
        state.crt_enabled = false;
        std.log.warn("CRT filter disabled: shader creation failed on backend {s}", .{@tagName(backend)});
        return;
    };

    var desc: sg.PipelineDesc = .{};
    desc.shader = state.crt_shader;
    desc.layout.attrs[0].format = .FLOAT2;
    desc.layout.buffers[0].stride = @sizeOf([2]f32);
    desc.primitive_type = .TRIANGLES;
    desc.colors[0].blend.enabled = true;
    desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
    desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
    desc.colors[0].blend.src_factor_alpha = .ONE;
    desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA;
    state.crt_pipeline = sg.makePipeline(desc);
    if (state.crt_pipeline.id == 0) {
        sg.destroyShader(state.crt_shader);
        state.crt_shader = .{};
        sg.destroyBuffer(state.crt_vertex_buffer);
        state.crt_vertex_buffer = .{};
        state.crt_enabled = false;
        std.log.warn("CRT filter disabled: pipeline creation failed", .{});
    }
}

fn drawCrtOverlay() void {
    if (!state.crt_enabled or state.crt_pipeline.id == 0 or state.crt_vertex_buffer.id == 0) {
        return;
    }

    sg.applyPipeline(state.crt_pipeline);
    var bindings: sg.Bindings = .{};
    bindings.vertex_buffers[0] = state.crt_vertex_buffer;
    sg.applyBindings(bindings);
    sg.draw(0, 3, 1);
}

fn initDitherPipeline() void {
    const dither_vertices = [_]f32{
        -1.0, -1.0,
        3.0,  -1.0,
        -1.0, 3.0,
    };
    state.dither_vertex_buffer = sg.makeBuffer(.{
        .usage = .{
            .vertex_buffer = true,
            .immutable = true,
        },
        .data = sg.asRange(&dither_vertices),
    });
    if (state.dither_vertex_buffer.id == 0) {
        state.dither_enabled = false;
        std.log.warn("B/W dither disabled: fullscreen triangle buffer creation failed", .{});
        return;
    }

    const backend = sg.queryBackend();
    state.dither_shader = makeDitherShader(backend) orelse {
        sg.destroyBuffer(state.dither_vertex_buffer);
        state.dither_vertex_buffer = .{};
        state.dither_enabled = false;
        std.log.warn("B/W dither disabled: shader creation failed on backend {s}", .{@tagName(backend)});
        return;
    };

    var desc: sg.PipelineDesc = .{};
    desc.shader = state.dither_shader;
    desc.layout.attrs[0].format = .FLOAT2;
    desc.layout.buffers[0].stride = @sizeOf([2]f32);
    desc.primitive_type = .TRIANGLES;
    state.dither_pipeline = sg.makePipeline(desc);
    if (state.dither_pipeline.id == 0) {
        sg.destroyShader(state.dither_shader);
        state.dither_shader = .{};
        sg.destroyBuffer(state.dither_vertex_buffer);
        state.dither_vertex_buffer = .{};
        state.dither_enabled = false;
        std.log.warn("B/W dither disabled: pipeline creation failed", .{});
    }
}

fn destroyDitherSceneTargets() void {
    if (state.dither_scene_texture_view.id != 0) {
        sg.destroyView(state.dither_scene_texture_view);
        state.dither_scene_texture_view = .{};
    }
    if (state.dither_scene_depth_view.id != 0) {
        sg.destroyView(state.dither_scene_depth_view);
        state.dither_scene_depth_view = .{};
    }
    if (state.dither_scene_resolve_view.id != 0) {
        sg.destroyView(state.dither_scene_resolve_view);
        state.dither_scene_resolve_view = .{};
    }
    if (state.dither_scene_msaa_view.id != 0) {
        sg.destroyView(state.dither_scene_msaa_view);
        state.dither_scene_msaa_view = .{};
    }

    if (state.dither_scene_resolve_image.id != 0) {
        sg.destroyImage(state.dither_scene_resolve_image);
        state.dither_scene_resolve_image = .{};
    }
    if (state.dither_scene_depth_image.id != 0) {
        sg.destroyImage(state.dither_scene_depth_image);
        state.dither_scene_depth_image = .{};
    }
    if (state.dither_scene_msaa_image.id != 0) {
        sg.destroyImage(state.dither_scene_msaa_image);
        state.dither_scene_msaa_image = .{};
    }

    state.dither_target_w = 0;
    state.dither_target_h = 0;
    state.dither_target_sample_count = 0;
}

fn recreateDitherSceneTargets(width: i32, height: i32, sample_count: i32) bool {
    destroyDitherSceneTargets();

    const defaults = sg.queryDesc().environment.defaults;
    var color_format = defaults.color_format;
    if (color_format == .DEFAULT or color_format == .NONE) {
        color_format = .RGBA8;
    }
    var depth_format = defaults.depth_format;
    if (depth_format == .DEFAULT) {
        depth_format = .DEPTH_STENCIL;
    }

    state.dither_scene_msaa_image = sg.makeImage(.{
        .usage = .{
            .color_attachment = true,
            .immutable = true,
        },
        .width = width,
        .height = height,
        .pixel_format = color_format,
        .sample_count = sample_count,
    });
    if (state.dither_scene_msaa_image.id == 0) {
        std.log.warn("B/W dither disabled: failed creating offscreen color image {d}x{d}", .{ width, height });
        state.dither_enabled = false;
        return false;
    }

    state.dither_scene_msaa_view = sg.makeView(.{
        .color_attachment = .{
            .image = state.dither_scene_msaa_image,
        },
    });
    if (state.dither_scene_msaa_view.id == 0) {
        std.log.warn("B/W dither disabled: failed creating offscreen color view", .{});
        destroyDitherSceneTargets();
        state.dither_enabled = false;
        return false;
    }

    if (depth_format != .NONE) {
        state.dither_scene_depth_image = sg.makeImage(.{
            .usage = .{
                .depth_stencil_attachment = true,
                .immutable = true,
            },
            .width = width,
            .height = height,
            .pixel_format = depth_format,
            .sample_count = sample_count,
        });
        if (state.dither_scene_depth_image.id == 0) {
            std.log.warn("B/W dither disabled: failed creating offscreen depth image {d}x{d}", .{ width, height });
            destroyDitherSceneTargets();
            state.dither_enabled = false;
            return false;
        }

        state.dither_scene_depth_view = sg.makeView(.{
            .depth_stencil_attachment = .{
                .image = state.dither_scene_depth_image,
            },
        });
        if (state.dither_scene_depth_view.id == 0) {
            std.log.warn("B/W dither disabled: failed creating offscreen depth view", .{});
            destroyDitherSceneTargets();
            state.dither_enabled = false;
            return false;
        }
    }

    if (sample_count > 1) {
        state.dither_scene_resolve_image = sg.makeImage(.{
            .usage = .{
                .resolve_attachment = true,
                .immutable = true,
            },
            .width = width,
            .height = height,
            .pixel_format = color_format,
            .sample_count = 1,
        });
        if (state.dither_scene_resolve_image.id == 0) {
            std.log.warn("B/W dither disabled: failed creating resolve image {d}x{d}", .{ width, height });
            destroyDitherSceneTargets();
            state.dither_enabled = false;
            return false;
        }

        state.dither_scene_resolve_view = sg.makeView(.{
            .resolve_attachment = .{
                .image = state.dither_scene_resolve_image,
            },
        });
        if (state.dither_scene_resolve_view.id == 0) {
            std.log.warn("B/W dither disabled: failed creating resolve view", .{});
            destroyDitherSceneTargets();
            state.dither_enabled = false;
            return false;
        }

        state.dither_scene_texture_view = sg.makeView(.{
            .texture = .{
                .image = state.dither_scene_resolve_image,
            },
        });
    } else {
        state.dither_scene_texture_view = sg.makeView(.{
            .texture = .{
                .image = state.dither_scene_msaa_image,
            },
        });
    }

    if (state.dither_scene_texture_view.id == 0) {
        std.log.warn("B/W dither disabled: failed creating scene texture view", .{});
        destroyDitherSceneTargets();
        state.dither_enabled = false;
        return false;
    }

    state.dither_target_w = width;
    state.dither_target_h = height;
    state.dither_target_sample_count = sample_count;
    return true;
}

fn ensureDitherSceneTargets() bool {
    if (state.dither_pipeline.id == 0 or state.dither_vertex_buffer.id == 0) {
        return false;
    }

    const width = @max(1, sapp.width());
    const height = @max(1, sapp.height());
    var sample_count = sglue.swapchain().sample_count;
    if (sample_count <= 0) {
        sample_count = sg.queryDesc().environment.defaults.sample_count;
    }
    if (sample_count <= 0) {
        sample_count = 1;
    }

    if (state.dither_scene_msaa_view.id != 0 and
        state.dither_scene_texture_view.id != 0 and
        state.dither_target_w == width and
        state.dither_target_h == height and
        state.dither_target_sample_count == sample_count)
    {
        return true;
    }

    return recreateDitherSceneTargets(width, height, sample_count);
}

fn drawDitherComposite() void {
    if (!state.dither_enabled or
        state.dither_pipeline.id == 0 or
        state.dither_vertex_buffer.id == 0 or
        state.dither_scene_texture_view.id == 0)
    {
        return;
    }

    sg.applyPipeline(state.dither_pipeline);
    var bindings: sg.Bindings = .{};
    bindings.vertex_buffers[0] = state.dither_vertex_buffer;
    bindings.views[0] = state.dither_scene_texture_view;
    bindings.samplers[0] = state.sampler;
    sg.applyBindings(bindings);
    sg.draw(0, 3, 1);
}

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

fn mapBuffers() map_io.MapBuffers {
    return .{
        .floor = &state.map_floor,
        .wall = &state.map_wall,
        .roof = &state.map_roof,
        .wall_rot = &state.map_wall_rot,
        .roof_rot = &state.map_roof_rot,
    };
}

fn saveMapToDisk() !void {
    if (!canPersistMap()) {
        return error.UnsupportedPlatform;
    }
    try map_io.save(MapSavePath, mapBuffers());
}

fn tryLoadMapFromDisk(report_missing: bool, report_hud: bool) void {
    if (!canPersistMap()) {
        if (report_hud) {
            setHudMessage(.warning, HudMessageSeconds, "Map save/load unsupported in web build", .{});
        }
        return;
    }

    const result = map_io.load(MapSavePath, mapBuffers());
    switch (result.status) {
        .ok => {
            std.log.info("Loaded map layout from {s} (format v{d})", .{ MapSavePath, result.version });
            if (result.migrated) {
                std.log.info(
                    "Migrated map format from v{d} to v{d}",
                    .{ result.version, MapFormatVersionCurrent },
                );
                if (report_hud) {
                    setHudMessage(
                        .success,
                        HudMessageSeconds + 0.8,
                        "Loaded map v{d} and migrated to v{d}",
                        .{ result.version, MapFormatVersionCurrent },
                    );
                }
            } else if (report_hud) {
                setHudMessage(.success, HudMessageSeconds, "Loaded map v{d}", .{result.version});
            }
        },
        .not_found => {
            if (report_missing) {
                std.log.info("No saved map found at {s}", .{MapSavePath});
            }
            if (report_hud) {
                setHudMessage(.info, HudMessageSeconds, "No saved map at {s}", .{MapSavePath});
            }
        },
        .io_error => {
            const err = result.io_error orelse error.Unexpected;
            std.log.warn("Map IO error for {s}: {s}", .{ MapSavePath, @errorName(err) });
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map file IO error", .{});
            }
        },
        .invalid_magic => {
            std.log.warn("Ignoring map file {s}: invalid magic", .{MapSavePath});
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map file is invalid", .{});
            }
        },
        .unsupported_size => {
            if (result.version != 0 and result.expected_size != 0) {
                std.log.warn(
                    "Ignoring map file {s}: format v{d} expects {d} bytes, got {d}",
                    .{ MapSavePath, result.version, result.expected_size, result.actual_size },
                );
            } else {
                std.log.warn(
                    "Ignoring map file {s}: unsupported size {d} bytes",
                    .{ MapSavePath, result.actual_size },
                );
            }
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map file size/format unsupported", .{});
            }
        },
        .unsupported_version => {
            std.log.warn("Ignoring map file {s}: unsupported version {d}", .{ MapSavePath, result.version });
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map version {d} is unsupported", .{result.version});
            }
        },
        .dimension_mismatch => {
            std.log.warn(
                "Ignoring map file {s}: expected {d}x{d}, got {d}x{d}",
                .{ MapSavePath, MapW, MapH, result.read_w, result.read_h },
            );
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map dimensions mismatch ({d}x{d})", .{ result.read_w, result.read_h });
            }
        },
        .truncated => {
            std.log.warn("Ignoring map file {s}: truncated payload", .{MapSavePath});
            if (report_hud) {
                setHudMessage(.failure, HudMessageSeconds, "Map file is truncated", .{});
            }
        },
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
    return editor_sys.activeTileCount(&state);
}

fn activeWallCount() usize {
    return editor_sys.activeWallCount(&state);
}

fn activeRoofCount() usize {
    return editor_sys.activeRoofCount(&state);
}

fn currentBrushTile() u8 {
    return switch (state.editor_layer) {
        .floor => state.brush_floor_tile,
        .wall => state.brush_wall_tile,
        .roof => state.brush_roof_tile,
    };
}

fn setCurrentBrushTile(tile: u8) void {
    switch (state.editor_layer) {
        .floor => state.brush_floor_tile = tile,
        .wall => state.brush_wall_tile = tile,
        .roof => state.brush_roof_tile = tile,
    }
}

fn currentBrushRotation() u8 {
    return switch (state.editor_layer) {
        .floor => 0,
        .wall => state.brush_wall_rot % 4,
        .roof => state.brush_roof_rot % 4,
    };
}

fn rotateCurrentBrush(delta: i32) void {
    switch (state.editor_layer) {
        .floor => {},
        .wall => {
            const base: i32 = @intCast(state.brush_wall_rot % 4);
            const next = @mod(base + delta, 4);
            state.brush_wall_rot = @intCast(next);
        },
        .roof => {
            const base: i32 = @intCast(state.brush_roof_rot % 4);
            const next = @mod(base + delta, 4);
            state.brush_roof_rot = @intCast(next);
        },
    }
}

fn layerName(layer: EditorLayer) []const u8 {
    return switch (layer) {
        .floor => "Floor",
        .wall => "Wall",
        .roof => "Roof",
    };
}

fn setEditorLayer(layer: EditorLayer) void {
    state.editor_layer = layer;
    if (state.editor_mode) {
        setHudMessage(.info, 1.5, "{s} layer selected", .{layerName(layer)});
    }
}

fn setEditorEraseMode(enabled: bool) void {
    state.editor_erase_mode = enabled;
    if (state.editor_mode) {
        setHudMessage(
            .info,
            1.2,
            "Erase mode {s}",
            .{if (enabled) "ON" else "OFF"},
        );
    }
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
    state.paint_erase = false;
    if (enabled) {
        sapp.setWindowTitle("Zig Isometric RTS [Editor Mode]");
    } else {
        sapp.setWindowTitle("Zig Isometric RTS");
    }
}

fn paintAtWorld(world: Vec2, erase: bool) void {
    editor_sys.paintAtWorld(&state, world, erase);
}

fn pickTileAtWorld(world: Vec2) void {
    editor_sys.pickTileAtWorld(&state, world);
}

fn numberKeyFromKeycode(key: sapp.Keycode) ?u8 {
    return editor_sys.numberKeyFromKeycode(key);
}

fn applyNumberBrushShortcut(number_key: u8) void {
    editor_sys.applyNumberBrushShortcut(&state, number_key);
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

fn isCyanKey(r: u8, g: u8, b: u8) bool {
    const ri: i16 = r;
    const gi: i16 = g;
    const bi: i16 = b;
    const chroma_strength = (gi + bi) - (ri * 2);
    // Accept darker teal/cyan matte colors, not only bright cyan.
    return chroma_strength >= 70 and gi >= 90 and bi >= 90 and ri <= 140;
}

fn isChromaKey(r: u8, g: u8, b: u8) bool {
    return isMagentaKey(r, g, b) or isCyanKey(r, g, b);
}

fn applyMagentaKeyToAlpha(pixels: []u8) usize {
    var changed: usize = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        if (isChromaKey(pixels[i + 0], pixels[i + 1], pixels[i + 2])) {
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
    units_sys.clearSelection(&state);
}

fn pickUnitAtWorld(world: Vec2) ?usize {
    return units_sys.pickUnitAtWorld(&state, world);
}

fn selectByClick(mouse: Vec2, additive: bool) void {
    units_sys.selectByClick(&state, mouse, additive, screenToWorld);
}

fn selectByBox(a: Vec2, b: Vec2, additive: bool) void {
    units_sys.selectByBox(&state, a, b, additive, worldToScreen);
}

fn issueMoveOrder(mouse: Vec2) void {
    units_sys.issueMoveOrder(&state, mouse, screenToWorld, clampWorld);
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

fn appendWallFromPath(path: []const u8) bool {
    if (state.wall_count >= StructureVariants) {
        return false;
    }
    if (loadTileSprite(path)) |loaded_sprite| {
        var sprite = loaded_sprite;
        if (sprite.isValid()) {
            state.wall_sprites[state.wall_count] = sprite;
            state.wall_count += 1;
            std.log.info("Added wall variant {d}: {s}", .{ state.wall_count, path });
            return true;
        }
        destroySprite(&sprite);
    } else |_| {}
    return false;
}

fn appendRoofFromPath(path: []const u8) bool {
    if (state.roof_count >= StructureVariants) {
        return false;
    }
    if (loadTileSprite(path)) |loaded_sprite| {
        var sprite = loaded_sprite;
        if (sprite.isValid()) {
            state.roof_sprites[state.roof_count] = sprite;
            state.roof_count += 1;
            std.log.info("Added roof variant {d}: {s}", .{ state.roof_count, path });
            return true;
        }
        destroySprite(&sprite);
    } else |_| {}
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

    units_sys.updateUnits(&state, dt);

    if (state.hud_time_left > 0.0) {
        state.hud_time_left = @max(0.0, state.hud_time_left - dt);
    }
}

fn emitQuadCentered(cx: f32, cy: f32, w: f32, h: f32) void {
    render_sys.emitQuadCentered(cx, cy, w, h);
}

fn emitQuadBottom(cx: f32, by: f32, w: f32, h: f32) void {
    render_sys.emitQuadBottom(cx, by, w, h);
}

fn emitQuadBottomZRotated(world: Vec2, draw_h: f32, width_tiles: f32, rot: u8) void {
    render_sys.emitQuadBottomZRotated(world, draw_h, width_tiles, rot, worldToScreen);
}

const VisibleBounds = render_sys.VisibleBounds;

fn computeVisibleBounds() VisibleBounds {
    return render_sys.computeVisibleBounds(screenToWorld);
}

fn drawMap() void {
    render_sys.drawMap(&state, screenToWorld, worldToScreen);
}

fn drawStructureLayer(
    map_layer: *const [MapH][MapW]u8,
    rot_layer: *const [MapH][MapW]u8,
    sprites: []const Sprite,
    sprite_count: usize,
) void {
    render_sys.drawStructureLayer(&state, map_layer, rot_layer, sprites, sprite_count, screenToWorld, worldToScreen);
}

fn drawUnits() void {
    render_sys.drawUnits(&state, worldToScreen);
}

fn drawSelectionBox() void {
    render_sys.drawSelectionBox(state.drag);
}

fn setup2DProjection() void {
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.ortho(0.0, sapp.widthf(), sapp.heightf(), 0.0, -1.0, 1.0);

    sgl.matrixModeModelview();
    sgl.loadIdentity();
}

fn drawSceneGeometry() void {
    drawMap();
    drawStructureLayer(&state.map_wall, &state.map_wall_rot, state.wall_sprites[0..state.wall_count], state.wall_count);
    drawUnits();
    drawStructureLayer(&state.map_roof, &state.map_roof_rot, state.roof_sprites[0..state.roof_count], state.roof_count);
    if (!state.editor_mode) {
        drawSelectionBox();
    }
    drawEditorOverlay();
}

fn drawEditorBrushPreviewAtWorld(world: Vec2, alpha: f32) void {
    if (state.editor_erase_mode or state.paint_erase) {
        return;
    }
    switch (state.editor_layer) {
        .floor => {
            if (state.tile_count == 0) return;
            const idx = @as(usize, state.brush_floor_tile % @as(u8, @intCast(activeTileCount())));
            if (idx >= state.tile_count) return;
            const sprite = state.tile_sprites[idx];
            const screen = worldToScreen(world);

            sgl.loadPipeline(state.alpha_pipeline);
            sgl.enableTexture();
            sgl.texture(sprite.view, state.sampler);
            sgl.c4f(1.0, 1.0, 1.0, alpha);
            sgl.beginQuads();
            emitQuadCentered(screen.x, screen.y, sprite.width * state.zoom, sprite.height * state.zoom);
            sgl.end();
            sgl.disableTexture();
            sgl.loadDefaultPipeline();
        },
        .wall => {
            if (state.brush_wall_tile == 0 or state.wall_count == 0) return;
            const idx = @as(usize, (state.brush_wall_tile - 1) % @as(u8, @intCast(activeWallCount())));
            if (idx >= state.wall_count) return;
            const sprite = state.wall_sprites[idx];
            const structure_scale = @max(1.0, state.tile_world_w / 64.0);
            const draw_w = sprite.width * state.zoom * structure_scale;
            const draw_h = sprite.height * state.zoom * structure_scale;
            const width_tiles = @max(0.35, draw_w / (state.tile_world_w * state.zoom));

            sgl.loadPipeline(state.alpha_pipeline);
            sgl.enableTexture();
            sgl.texture(sprite.view, state.sampler);
            sgl.c4f(1.0, 1.0, 1.0, alpha);
            sgl.beginQuads();
            emitQuadBottomZRotated(world, draw_h, width_tiles, state.brush_wall_rot);
            sgl.end();
            sgl.disableTexture();
            sgl.loadDefaultPipeline();
        },
        .roof => {
            if (state.brush_roof_tile == 0 or state.roof_count == 0) return;
            const idx = @as(usize, (state.brush_roof_tile - 1) % @as(u8, @intCast(activeRoofCount())));
            if (idx >= state.roof_count) return;
            const sprite = state.roof_sprites[idx];
            const structure_scale = @max(1.0, state.tile_world_w / 64.0);
            const draw_w = sprite.width * state.zoom * structure_scale;
            const draw_h = sprite.height * state.zoom * structure_scale;
            const width_tiles = @max(0.35, draw_w / (state.tile_world_w * state.zoom));

            sgl.loadPipeline(state.alpha_pipeline);
            sgl.enableTexture();
            sgl.texture(sprite.view, state.sampler);
            sgl.c4f(1.0, 1.0, 1.0, alpha);
            sgl.beginQuads();
            emitQuadBottomZRotated(world, draw_h, width_tiles, state.brush_roof_rot);
            sgl.end();
            sgl.disableTexture();
            sgl.loadDefaultPipeline();
        },
    }
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
                const world = Vec2{
                    .x = @as(f32, @floatFromInt(tx)) + 0.5,
                    .y = @as(f32, @floatFromInt(ty)) + 0.5,
                };
                const rx = state.tile_world_w * 0.50 * state.zoom;
                const ry = state.tile_world_h * 0.50 * state.zoom;
                const is_center = ox == 0 and oy == 0;

                drawEditorBrushPreviewAtWorld(world, if (is_center) 0.78 else 0.42);

                sgl.disableTexture();
                sgl.c4f(
                    if (is_center) 1.0 else 0.95,
                    if (is_center) 0.92 else 0.95,
                    if (is_center) 0.35 else 0.95,
                    if (is_center) 0.95 else 0.70,
                );
                sgl.beginLineStrip();
                sgl.v2f(screen.x, screen.y - ry);
                sgl.v2f(screen.x + rx, screen.y);
                sgl.v2f(screen.x, screen.y + ry);
                sgl.v2f(screen.x - rx, screen.y);
                sgl.v2f(screen.x, screen.y - ry);
                sgl.end();

                const show_erase_cross = state.editor_erase_mode or state.paint_erase or
                    (state.editor_layer != .floor and currentBrushTile() == 0);
                if (show_erase_cross) {
                    sgl.c4f(0.95, 0.25, 0.25, if (is_center) 0.95 else 0.75);
                    sgl.beginLineStrip();
                    sgl.v2f(screen.x - rx * 0.62, screen.y - ry * 0.62);
                    sgl.v2f(screen.x + rx * 0.62, screen.y + ry * 0.62);
                    sgl.end();
                    sgl.beginLineStrip();
                    sgl.v2f(screen.x + rx * 0.62, screen.y - ry * 0.62);
                    sgl.v2f(screen.x - rx * 0.62, screen.y + ry * 0.62);
                    sgl.end();
                }
            }
        }
    }

    const sw = 44.0;
    const sh = 30.0;
    const pad = 6.0;
    const slot_count: usize = switch (state.editor_layer) {
        .floor => state.tile_count,
        .wall => state.wall_count + 1,
        .roof => state.roof_count + 1,
    };
    if (slot_count == 0) {
        return;
    }
    const selected_slot: usize = @as(usize, currentBrushTile());

    var i: usize = 0;
    while (i < slot_count) : (i += 1) {
        const x0 = 14.0 + @as(f32, @floatFromInt(i)) * (sw + pad);
        const y0 = 14.0;
        const x1 = x0 + sw;
        const y1 = y0 + sh;

        var sprite_opt: ?Sprite = null;
        switch (state.editor_layer) {
            .floor => {
                if (i < state.tile_count) sprite_opt = state.tile_sprites[i];
            },
            .wall => {
                if (i > 0 and i - 1 < state.wall_count) sprite_opt = state.wall_sprites[i - 1];
            },
            .roof => {
                if (i > 0 and i - 1 < state.roof_count) sprite_opt = state.roof_sprites[i - 1];
            },
        }

        if (sprite_opt) |sprite| {
            sgl.loadPipeline(state.alpha_pipeline);
            sgl.enableTexture();
            sgl.texture(sprite.view, state.sampler);
            sgl.c4f(1.0, 1.0, 1.0, 1.0);
            sgl.beginQuads();
            sgl.v2fT2f(x0, y0, 0.0, 0.0);
            sgl.v2fT2f(x1, y0, 1.0, 0.0);
            sgl.v2fT2f(x1, y1, 1.0, 1.0);
            sgl.v2fT2f(x0, y1, 0.0, 1.0);
            sgl.end();
        } else {
            sgl.disableTexture();
            sgl.loadDefaultPipeline();
            sgl.c4f(0.12, 0.12, 0.12, 0.92);
            sgl.beginQuads();
            sgl.v2f(x0, y0);
            sgl.v2f(x1, y0);
            sgl.v2f(x1, y1);
            sgl.v2f(x0, y1);
            sgl.end();

            sgl.c4f(0.55, 0.55, 0.55, 0.95);
            sgl.beginLineStrip();
            sgl.v2f(x0 + 6, y0 + 6);
            sgl.v2f(x1 - 6, y1 - 6);
            sgl.end();
            sgl.beginLineStrip();
            sgl.v2f(x1 - 6, y0 + 6);
            sgl.v2f(x0 + 6, y1 - 6);
            sgl.end();
        }

        sgl.disableTexture();
        sgl.loadDefaultPipeline();
        const is_selected = i == selected_slot;
        sgl.c4f(if (is_selected) 0.15 else 0.05, if (is_selected) 1.0 else 0.05, if (is_selected) 0.20 else 0.05, 0.95);
        sgl.beginLineStrip();
        sgl.v2f(x0, y0);
        sgl.v2f(x1, y0);
        sgl.v2f(x1, y1);
        sgl.v2f(x0, y1);
        sgl.v2f(x0, y0);
        sgl.end();
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
    initDitherPipeline();
    initCrtPipeline();
    _ = ensureDitherSceneTargets();

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
    const wall_candidates = [_][]const u8{
        assetPath("SBS - Isometric Town Pack/Building Tiles/Isometric Buildings 1 - 64x96.png"),
        assetPath("SBS - Isometric Town Pack/Building Tiles/Isometric Buildings 2 - 64x96.png"),
        assetPath("SBS - Isometric Town Pack/Building Tiles/Isometric Buildings 3 - 64x96.png"),
    };
    const roof_candidates = [_][]const u8{
        assetPath("SBS - Isometric Town Pack/Roof Tiles/Isometric Town Roofing - 143x92.png"),
    };
    const discovered = discoverIsoTownPaths();

    state.tile_count = 0;
    state.wall_count = 0;
    state.roof_count = 0;

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
    for (wall_candidates) |path| {
        _ = appendWallFromPath(path);
        if (state.wall_count >= StructureVariants) break;
    }
    for (roof_candidates) |path| {
        _ = appendRoofFromPath(path);
        if (state.roof_count >= StructureVariants) break;
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
            state.map_floor[y][x] = @intCast((x * 11 + y * 7) % activeTileCount());
            state.map_wall[y][x] = 0;
            state.map_roof[y][x] = 0;
            state.map_wall_rot[y][x] = 0;
            state.map_roof_rot[y][x] = 0;
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
    state.editor_layer = .floor;
    state.brush_floor_tile = 0;
    state.brush_wall_tile = if (state.wall_count > 0) 1 else 0;
    state.brush_roof_tile = if (state.roof_count > 0) 1 else 0;
    state.brush_wall_rot = 0;
    state.brush_roof_rot = 0;
    state.editor_erase_mode = false;
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

    const use_dither = state.dither_enabled and ensureDitherSceneTargets();

    if (use_dither) {
        var attachments: sg.Attachments = .{};
        attachments.colors[0] = state.dither_scene_msaa_view;
        if (state.dither_target_sample_count > 1) {
            attachments.resolves[0] = state.dither_scene_resolve_view;
        }
        if (state.dither_scene_depth_view.id != 0) {
            attachments.depth_stencil = state.dither_scene_depth_view;
        }

        sg.beginPass(.{
            .action = state.pass_action,
            .attachments = attachments,
        });
        setup2DProjection();
        drawSceneGeometry();
        sgl.draw();
        sg.endPass();

        sg.beginPass(.{
            .action = state.pass_action,
            .swapchain = sglue.swapchain(),
        });
        drawDitherComposite();
    } else {
        sg.beginPass(.{
            .action = state.pass_action,
            .swapchain = sglue.swapchain(),
        });
        setup2DProjection();
        drawSceneGeometry();
        sgl.draw();
    }

    drawCrtOverlay();
    setup2DProjection();
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
    i = 0;
    while (i < state.wall_count) : (i += 1) {
        destroySprite(&state.wall_sprites[i]);
    }
    i = 0;
    while (i < state.roof_count) : (i += 1) {
        destroySprite(&state.roof_sprites[i]);
    }
    destroySprite(&state.unit_blue_sprite);
    destroySprite(&state.unit_red_sprite);

    destroyDitherSceneTargets();

    if (state.sampler.id != 0) {
        sg.destroySampler(state.sampler);
    }
    if (state.alpha_pipeline.id != 0) {
        sgl.destroyPipeline(state.alpha_pipeline);
    }
    if (state.dither_vertex_buffer.id != 0) {
        sg.destroyBuffer(state.dither_vertex_buffer);
    }
    if (state.dither_pipeline.id != 0) {
        sg.destroyPipeline(state.dither_pipeline);
    }
    if (state.dither_shader.id != 0) {
        sg.destroyShader(state.dither_shader);
    }
    if (state.crt_vertex_buffer.id != 0) {
        sg.destroyBuffer(state.crt_vertex_buffer);
    }
    if (state.crt_pipeline.id != 0) {
        sg.destroyPipeline(state.crt_pipeline);
    }
    if (state.crt_shader.id != 0) {
        sg.destroyShader(state.crt_shader);
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
            if (e.key_code == .C) {
                if (state.crt_pipeline.id != 0) {
                    state.crt_enabled = !state.crt_enabled;
                    setHudMessage(.info, 1.2, "CRT filter {s}", .{if (state.crt_enabled) "ON" else "OFF"});
                } else {
                    setHudMessage(.warning, 1.6, "CRT filter unavailable on this backend", .{});
                }
            }
            if (e.key_code == .V) {
                if (state.dither_pipeline.id != 0 and state.dither_vertex_buffer.id != 0) {
                    state.dither_enabled = !state.dither_enabled;
                    setHudMessage(.info, 1.2, "B/W dither {s}", .{if (state.dither_enabled) "ON" else "OFF"});
                } else {
                    setHudMessage(.warning, 1.6, "B/W dither unavailable on this backend", .{});
                }
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
                if (e.key_code == .F) {
                    setEditorLayer(.floor);
                } else if (e.key_code == .B) {
                    setEditorLayer(.wall);
                } else if (e.key_code == .R) {
                    setEditorLayer(.roof);
                } else if (e.key_code == .X) {
                    setEditorEraseMode(!state.editor_erase_mode);
                } else if (e.key_code == .Q) {
                    rotateCurrentBrush(-1);
                    if (state.editor_layer != .floor) {
                        setHudMessage(
                            .info,
                            1.4,
                            "{s} rotation {d}",
                            .{ layerName(state.editor_layer), @as(u32, currentBrushRotation()) * 90 },
                        );
                    }
                } else if (e.key_code == .E) {
                    rotateCurrentBrush(1);
                    if (state.editor_layer != .floor) {
                        setHudMessage(
                            .info,
                            1.4,
                            "{s} rotation {d}",
                            .{ layerName(state.editor_layer), @as(u32, currentBrushRotation()) * 90 },
                        );
                    }
                }
                if (numberKeyFromKeycode(e.key_code)) |number_key| {
                    applyNumberBrushShortcut(number_key);
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
                state.paint_erase = state.editor_erase_mode or ((e.modifiers & sapp.modifier_alt) != 0);
                paintAtWorld(screenToWorld(state.mouse_screen), state.paint_erase);
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
                paintAtWorld(screenToWorld(state.mouse_screen), state.paint_erase);
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
                state.paint_erase = false;
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
