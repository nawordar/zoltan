const lualib = @import("./lualib.zig");
const util = @import("./util.zig");

const Lua = @import("./Lua.zig");

const Self = @This();

state: *lualib.lua_State,
ref: c_int,

// This 'Init' assumes, that the top element of the stack is a Lua table
pub fn init(state: *lualib.lua_State) Self {
    const ref = lualib.luaL_ref(state, lualib.LUA_REGISTRYINDEX);

    return .{
        .state = state,
        .ref = ref,
    };
}

// Unregister this shit
pub fn destroy(self: *const Self) void {
    lualib.luaL_unref(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
}

pub fn clone(self: *const Self) Self {
    _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
    return Self.init(self.state, self.allocator);
}

pub fn set(self: *const Self, key: anytype, value: anytype) void {
    // Getting table reference
    _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
    // Push key, value
    util.push(self.state, key);
    util.push(self.state, value);
    // Set
    lualib.lua_settable(self.state, -3);
}

pub fn get(self: *const Self, comptime T: type, key: anytype) !T {
    // Getting table by reference
    _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
    // Push key
    util.push(self.state, key);
    // Get
    _ = lualib.lua_gettable(self.state, -2);
    return try util.pop(T, self.state);
}

pub fn getResource(self: *const Self, comptime T: type, key: anytype) !T {
    // Getting table reference
    _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
    // Push key
    util.push(self.state, key);
    // Get
    _ = lualib.lua_gettable(self.state, -2);
    return try util.popResource(T, self.state);
}
