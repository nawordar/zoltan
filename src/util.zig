const std = @import("std");

const lualib = @import("./lualib.zig");
const types = @import("./types.zig");

pub const LuaUserData = @import("./LuaUserData.zig");

pub const ZigCallHelper = types.ZigCallHelper;

// It is a helper function, with two responsibilities:
// 1. When it's called with only a type (allocator and value are both null) in compile time it returns that
//    the given type is allocated or not
// 2. When it's called with full arguments it cleans up.
pub fn allocateDeallocateHelper(
    comptime T: type,
    comptime deallocate: bool,
    allocator: ?std.mem.Allocator,
    value: ?T,
) bool {
    switch (@typeInfo(T)) {
        .Pointer => |PointerInfo| switch (PointerInfo.size) {
            .Slice => {
                if (PointerInfo.child == u8 and PointerInfo.is_const) {
                    return false;
                } else {
                    if (deallocate) {
                        allocator.?.free(value.?);
                    }
                    return true;
                }
            },
            else => return false,
        },
        .Struct => |_| {
            comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
            comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
            comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
            if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
                if (deallocate) {
                    value.?.destroy();
                }
                return true;
            } else return false;
        },
        else => {
            return false;
        },
    }
}

pub fn pop(comptime T: type, state: *lualib.lua_State) !T {
    defer lualib.lua_pop(state, 1);
    switch (@typeInfo(T)) {
        .Bool => {
            var res = lualib.lua_toboolean(state, -1);
            return if (res > 0) true else false;
        },
        .Int, .ComptimeInt => {
            var isnum: i32 = 0;
            var result: T = @intCast(T, lualib.lua_tointegerx(state, -1, isnum));
            return result;
        },
        .Float, .ComptimeFloat => {
            var isnum: i32 = 0;
            var result: T = @floatCast(T, lualib.lua_tonumberx(state, -1, isnum));
            return result;
        },
        // Only string, allocless get (Lua holds the pointer, it is only a slice pointing to it)
        .Pointer => |PointerInfo| switch (PointerInfo.size) {
            .Slice => {
                // [] const u8 case
                if (PointerInfo.child == u8 and PointerInfo.is_const) {
                    var len: usize = 0;
                    var ptr = lualib.lua_tolstring(state, -1, @ptrCast([*c]usize, &len));
                    var result: T = ptr[0..len];
                    return result;
                } else @compileError("Only '[]const u8' (aka string) is supported allocless.");
            },
            .One => {
                var optionalTbl = getUserData(state).registered_types.get(@typeName(PointerInfo.child));
                if (optionalTbl) |tbl| {
                    var result = @ptrCast(T, @alignCast(@alignOf(PointerInfo.child), lualib.luaL_checkudata(state, -1, @ptrCast([*c]const u8, tbl[0..]))));
                    return result;
                } else {
                    return error.invalidType;
                }
            },
            else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
        },
        .Struct => |StructInfo| {
            if (StructInfo.is_tuple) {
                @compileError("Tuples are not supported.");
            }
            comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
            comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
            if (funIdx >= 0 or tblIdx >= 0) {
                @compileError("Only allocGet supports Lua.Function and Lua.Table. Your type '" ++ @typeName(T) ++ "' is not supported.");
            }

            var result: T = .{ 0, 0 };
            comptime var i = 0;
            const fields_info = std.meta.fields(T);
            inline while (i < fields_info.len) : (i += 1) {
                result[i] = pop(@TypeOf(result[i]), state);
            }
        },
        else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
    }
}

pub fn popResource(comptime T: type, state: *lualib.lua_State) !T {
    switch (@typeInfo(T)) {
        .Pointer => |PointerInfo| switch (PointerInfo.size) {
            .Slice => {
                defer lualib.lua_pop(state, 1);
                if (lualib.lua_type(state, -1) == lualib.LUA_TTABLE) {
                    lualib.lua_len(state, -1);
                    const len = try pop(u64, state);
                    var res = try getAllocator(state).alloc(PointerInfo.child, @intCast(usize, len));
                    var i: u32 = 0;
                    while (i < len) : (i += 1) {
                        push(state, i + 1);
                        _ = lualib.lua_gettable(state, -2);
                        res[i] = try pop(PointerInfo.child, state);
                    }
                    return res;
                } else {
                    return error.bad_type;
                }
            },
            else => @compileError("Only Slice is supported."),
        },
        .Struct => |_| {
            comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
            comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
            comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
            if (funIdx >= 0) {
                if (lualib.lua_type(state, -1) == lualib.LUA_TFUNCTION) {
                    return T.init(state);
                } else {
                    defer lualib.lua_pop(state, 1);
                    return error.bad_type;
                }
            } else if (tblIdx >= 0) {
                if (lualib.lua_type(state, -1) == lualib.LUA_TTABLE) {
                    return T.init(state);
                } else {
                    defer lualib.lua_pop(state, 1);
                    return error.bad_type;
                }
            } else if (refIdx >= 0) {
                if (lualib.lua_type(state, -1) == lualib.LUA_TUSERDATA) {
                    return T.init(state);
                } else {
                    defer lualib.lua_pop(state, 1);
                    return error.bad_type;
                }
            } else @compileError("Only Function supported; '" ++ @typeName(T) ++ "' not.");
        },
        else => @compileError("invalid type: '" ++ @typeName(T) ++ "'"),
    }
}

pub fn push(state: *lualib.lua_State, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Void => lualib.lua_pushnil(state),
        .Bool => lualib.lua_pushboolean(state, @boolToInt(value)),
        .Int, .ComptimeInt => lualib.lua_pushinteger(state, @intCast(c_longlong, value)),
        .Float, .ComptimeFloat => lualib.lua_pushnumber(state, value),
        .Array => |info| {
            pushSlice(info.child, state, value[0..]);
        },
        .Pointer => |PointerInfo| switch (PointerInfo.size) {
            .Slice => {
                if (PointerInfo.child == u8) {
                    _ = lualib.lua_pushlstring(state, value.ptr, value.len);
                } else {
                    @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                }
            },
            .One => {
                switch (@typeInfo(PointerInfo.child)) {
                    .Array => |childInfo| {
                        if (childInfo.child == u8) {
                            _ = lualib.lua_pushstring(state, @ptrCast([*c]const u8, value));
                        } else {
                            @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                        }
                    },
                    .Struct => {
                        unreachable;
                    },
                    else => @compileError("BAszomalassan"),
                }
            },
            .Many => {
                if (PointerInfo.child == u8) {
                    _ = lualib.lua_pushstring(state, @ptrCast([*c]const u8, value));
                } else {
                    @compileError("invalid type: '" ++ @typeName(T) ++ "'. Typeinfo: '" ++ @typeInfo(PointerInfo.child) ++ "'");
                }
            },
            .C => {
                if (PointerInfo.child == u8) {
                    _ = lualib.lua_pushstring(state, value);
                } else {
                    @compileError("invalid type: '" ++ @typeName(T) ++ "'");
                }
            },
        },
        .Fn => {
            const Helper = ZigCallHelper(@TypeOf(value));
            Helper.pushFunctor(state, value) catch unreachable;
        },
        .Struct => |_| {
            comptime var funIdx = std.mem.indexOf(u8, @typeName(T), "Function") orelse -1;
            comptime var tblIdx = std.mem.indexOf(u8, @typeName(T), "Table") orelse -1;
            comptime var refIdx = std.mem.indexOf(u8, @typeName(T), "Ref(") orelse -1;
            if (funIdx >= 0 or tblIdx >= 0 or refIdx >= 0) {
                _ = lualib.lua_rawgeti(state, lualib.LUA_REGISTRYINDEX, value.ref);
            } else @compileError("Only Function ands Lua.Table supported; '" ++ @typeName(T) ++ "' not.");
        },
        else => @compileError("Unsupported type: '" ++ @typeName(@TypeOf(value)) ++ "'"),
    }
}

fn pushSlice(comptime T: type, state: *lualib.lua_State, values: []const T) void {
    lualib.lua_createtable(state, @intCast(c_int, values.len), 0);

    for (values) |value, i| {
        push(state, i + 1);
        push(state, value);
        lualib.lua_settable(state, -3);
    }
}

pub fn getUserData(state: ?*lualib.lua_State) *LuaUserData {
    var user_data: ?*anyopaque = null;
    _ = lualib.lua_getallocf(state, @ptrCast([*c]?*anyopaque, &user_data));
    return @ptrCast(*LuaUserData, @alignCast(@alignOf(LuaUserData), user_data));
}

pub fn getAllocator(state: ?*lualib.lua_State) std.mem.Allocator {
    return getUserData(state).allocator;
}
