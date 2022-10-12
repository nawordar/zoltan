const std = @import("std");

const lualib = @import("./lualib.zig");
const types = @import("./types.zig");
const util = @import("./util.zig");

pub const LuaUserData = @import("./LuaUserData.zig");
pub const Table = @import("./Table.zig");

pub const Function = types.Function;
pub const Ref = types.Ref;
pub const ZigCallHelper = types.ZigCallHelper;

const Lua = @This();

state: *lualib.lua_State,
ud: *LuaUserData,

pub fn init(allocator: std.mem.Allocator) !Lua {
    var user_data = try allocator.create(LuaUserData);
    user_data.* = LuaUserData.init(allocator);

    var state = lualib.lua_newstate(alloc, user_data) orelse return error.OutOfMemory;

    return Lua{
        .state = state,
        .ud = user_data,
    };
}

pub fn destroy(self: *Lua) void {
    _ = lualib.lua_close(self.state);
    self.ud.destroy();
    var allocator = self.ud.allocator;
    allocator.destroy(self.ud);
}

pub fn openLibs(self: *Lua) void {
    _ = lualib.luaL_openlibs(self.state);
}

pub fn injectPrettyPrint(self: *Lua) void {
    const cmd =
        \\-- Print contents of `tbl`, with indentation.
        \\-- `indent` sets the initial level of indentation.
        \\function pretty_print (tbl, indent)
        \\  if not indent then indent = 0 end
        \\  for k, v in pairs(tbl) do
        \\    formatting = string.rep("  ", indent) .. k .. ": "
        \\    if type(v) == "table" then
        \\      print(formatting)
        \\      pretty_print(v, indent+1)
        \\    elseif type(v) == 'boolean' then
        \\      print(formatting .. tostring(v))
        \\    else
        \\      print(formatting .. v)
        \\    end
        \\  end
        \\end
    ;
    self.run(cmd);
}

pub fn run(self: *Lua, script: []const u8) void {
    _ = lualib.luaL_loadstring(self.state, @ptrCast([*c]const u8, script));
    _ = lualib.lua_pcallk(self.state, 0, 0, 0, 0, null);
}

pub fn set(self: *Lua, name: []const u8, value: anytype) void {
    _ = util.push(self.state, value);
    _ = lualib.lua_setglobal(self.state, @ptrCast([*c]const u8, name));
}

pub fn get(self: *Lua, comptime T: type, name: []const u8) !T {
    const typ = lualib.lua_getglobal(self.state, @ptrCast([*c]const u8, name));
    if (typ != lualib.LUA_TNIL) {
        return try util.pop(T, self.state);
    } else {
        return error.novalue;
    }
}

pub fn getResource(self: *Lua, comptime T: type, name: []const u8) !T {
    const typ = lualib.lua_getglobal(self.state, @ptrCast([*c]const u8, name));
    if (typ != lualib.LUA_TNIL) {
        return try util.popResource(T, self.state);
    } else {
        return error.novalue;
    }
}

pub fn createTable(self: *Lua) !Lua.Table {
    _ = lualib.lua_createtable(self.state, 0, 0);
    return try util.popResource(Lua.Table, self.state);
}

pub fn createUserType(self: *Lua, comptime T: type, params: anytype) !Ref(T) {
    var metaTableName: []const u8 = undefined;
    // Allocate memory
    var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(self.state, @sizeOf(T))));
    // set its metatable
    if (util.getUserData(self.state).registered_types.get(@typeName(T))) |name| {
        metaTableName = name;
    } else {
        return error.unregistered_type;
    }
    _ = lualib.luaL_getmetatable(self.state, @ptrCast([*c]const u8, metaTableName[0..]));
    _ = lualib.lua_setmetatable(self.state, -2);
    // (3) init & copy wrapped object
    // Call init
    const ArgTypes = std.meta.ArgsTuple(@TypeOf(T.init));
    var args: ArgTypes = undefined;
    const fields_info = std.meta.fields(@TypeOf(params));
    const len = args.len;
    comptime var idx = 0;
    inline while (idx < len) : (idx += 1) {
        args[idx] = @field(params, fields_info[idx].name);
    }
    ptr.* = @call(.{}, T.init, args);
    // (4) check and store the callback table
    //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
    _ = lualib.lua_pushvalue(self.state, 1);
    _ = lualib.lua_setuservalue(self.state, -2);
    var res = try util.popResource(Ref(T), self.state);
    res.ptr = ptr;
    return res;
}

pub fn release(self: *Lua, v: anytype) void {
    _ = util.allocateDeallocateHelper(@TypeOf(v), true, self.ud.allocator, v);
}

pub fn newUserType(self: *Lua, comptime T: type) !void {
    comptime var hasInit: bool = false;
    comptime var hasDestroy: bool = false;
    comptime var metaTblName: [1024]u8 = undefined;
    _ = comptime try std.fmt.bufPrint(metaTblName[0..], "{s}", .{@typeName(T)});
    // Init Lua states
    comptime var allocFuns = struct {
        fn new(L: ?*lualib.lua_State) callconv(.C) c_int {
            // (1) get arguments
            var caller = ZigCallHelper(@TypeOf(T.init)).LowLevelHelpers.init();
            caller.prepareArgs(L) catch unreachable;

            // (2) create Lua object
            var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.lua_newuserdata(L, @sizeOf(T))));
            // set its metatable
            _ = lualib.luaL_getmetatable(L, @ptrCast([*c]const u8, metaTblName[0..]));
            _ = lualib.lua_setmetatable(L, -2);
            // (3) init & copy wrapped object
            caller.call(T.init) catch unreachable;
            ptr.* = caller.result;
            // (4) check and store the callback table
            //_ = lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
            _ = lualib.lua_pushvalue(L, 1);
            _ = lualib.lua_setuservalue(L, -2);

            return 1;
        }

        fn gc(L: ?*lualib.lua_State) callconv(.C) c_int {
            var ptr = @ptrCast(*T, @alignCast(@alignOf(T), lualib.luaL_checkudata(L, 1, @ptrCast([*c]const u8, metaTblName[0..]))));
            ptr.destroy();
            return 0;
        }
    };
    // Create metatable
    _ = lualib.luaL_newmetatable(self.state, @ptrCast([*c]const u8, metaTblName[0..]));
    // Metatable.__index = metatable
    lualib.lua_pushvalue(self.state, -1);
    lualib.lua_setfield(self.state, -2, "__index");

    //lua.luaL_setfuncs(self.L, &methods, 0); =>
    lualib.lua_pushcclosure(self.state, allocFuns.gc, 0);
    lualib.lua_setfield(self.state, -2, "__gc");

    // Collect information
    switch (@typeInfo(T)) {
        .Struct => |StructInfo| {
            inline for (StructInfo.decls) |decl| {
                switch (decl.data) {
                    .Fn => |_| {
                        if (comptime std.mem.eql(u8, decl.name, "init") == true) {
                            hasInit = true;
                        } else if (comptime std.mem.eql(u8, decl.name, "destroy") == true) {
                            hasDestroy = true;
                        } else if (decl.is_pub) {
                            comptime var field = @field(T, decl.name);
                            const Caller = ZigCallHelper(@TypeOf(field));
                            Caller.pushFunctor(self.state, field) catch unreachable;
                            lualib.lua_setfield(self.state, -2, @ptrCast([*c]const u8, decl.name));
                        }
                    },
                    else => {},
                }
            }
        },
        else => @compileError("Only Struct supported."),
    }
    if ((hasInit == false) or (hasDestroy == false)) {
        @compileError("Struct has to have init and destroy methods.");
    }
    // Only the 'new' function
    // <==_ = lua.luaL_newlib(lua.L, &arraylib_f); ==>
    lualib.luaL_checkversion(self.state);
    lualib.lua_createtable(self.state, 0, 1);
    // lua.luaL_setfuncs(self.L, &funcs, 0); =>
    lualib.lua_pushcclosure(self.state, allocFuns.new, 0);
    lualib.lua_setfield(self.state, -2, "new");

    // Set as global ('require' requires luaopen_{libraname} named static C functionsa and we don't want to provide one)
    _ = lualib.lua_setglobal(self.state, @ptrCast([*c]const u8, metaTblName[0..]));

    // Store in the registry
    try util.getUserData(self.state).registered_types.put(@typeName(T), metaTblName[0..]);
}

// Credit: https://github.com/daurnimator/zig-autolua
fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    const c_alignment = 16;
    const user_data = @ptrCast(*LuaUserData, @alignCast(@alignOf(LuaUserData), ud));
    if (@ptrCast(?[*]align(c_alignment) u8, @alignCast(c_alignment, ptr))) |previous_pointer| {
        const previous_slice = previous_pointer[0..osize];
        if (osize >= nsize) {
            // Lua assumes that the allocator never fails when osize >= nsize.
            return user_data.allocator.alignedShrink(previous_slice, c_alignment, nsize).ptr;
        } else {
            return (user_data.allocator.reallocAdvanced(
                previous_slice,
                c_alignment,
                nsize,
                .exact,
            ) catch return null).ptr;
        }
    } else {
        // osize is any of LUA_TSTRING, LUA_TTABLE, LUA_TFUNCTION, LUA_TUSERDATA, or LUA_TTHREAD
        // when (and only when) Lua is creating a new object of that type.
        // When osize is some other value, Lua is allocating memory for something else.
        return (user_data.allocator.alignedAlloc(u8, c_alignment, nsize) catch return null).ptr;
    }
}
