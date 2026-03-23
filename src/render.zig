// Terminal Renderer — Spec 9

pub const terminal = @import("render/terminal.zig");
pub const json = @import("render/json.zig");

pub const Renderer = terminal.Renderer;
pub const JsonRenderer = json.JsonRenderer;

test {
    @import("std").testing.refAllDecls(@This());
}
