const std = @import("std");

pub const Lua = @import("./Lua.zig");
pub const LuaUserData = @import("./LuaUserData.zig");

const assert = std.debug.assert;

pub fn main() anyerror!void {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.destroy();
    lua.openLibs();

    var tbl = try lua.createTable();
    defer lua.release(tbl);
    tbl.set("welcome", "All your codebase are belong to us.");
    lua.set("zig", tbl);
    lua.run("print(zig.welcome)");
}
