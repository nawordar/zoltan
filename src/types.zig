const std = @import("std");

const lualib = @import("./lualib.zig");
const util = @import("./util.zig");

const Lua = @import("./Lua.zig");

pub fn Function(comptime T: type) type {
    const FuncType = T;

    const RetType =
        switch (@typeInfo(FuncType)) {
        .Fn => |FunctionInfo| FunctionInfo.return_type,
        else => @compileError("Unsupported type."),
    };

    return struct {
        const Self = @This();

        state: *lualib.lua_State,
        ref: c_int = undefined,
        func: FuncType = undefined,

        // This 'Init' assumes that the top element of the stack is a Lua function
        pub fn init(state: *lualib.lua_State) Self {
            const _ref = lualib.luaL_ref(state, lualib.LUA_REGISTRYINDEX);
            var res = Self{
                .state = state,
                .ref = _ref,
            };
            return res;
        }

        pub fn destroy(self: *const Self) void {
            lualib.luaL_unref(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
        }

        pub fn call(self: *const Self, args: anytype) !RetType.? {
            const ArgsType = @TypeOf(args);
            if (@typeInfo(ArgsType) != .Struct) {
                ("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }
            // Getting function reference
            _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
            // Preparing arguments
            comptime var i = 0;
            const fields_info = std.meta.fields(ArgsType);
            inline while (i < fields_info.len) : (i += 1) {
                util.push(self.state, args[i]);
            }
            // Calculating retval count
            comptime var retValCount = switch (@typeInfo(RetType.?)) {
                .Void => 0,
                .Struct => |StructInfo| StructInfo.fields.len,
                else => 1,
            };
            // Calling
            if (lualib.lua_pcallk(self.state, fields_info.len, retValCount, 0, 0, null) != lualib.LUA_OK) {
                return error.lua_runtime_error;
            }
            // Getting return value(s)
            if (retValCount > 0) {
                return util.pop(RetType.?, self.state);
            }
        }
    };
}

pub fn Ref(comptime T: type) type {
    return struct {
        const Self = @This();

        state: *lualib.lua_State,
        ref: c_int = undefined,
        ptr: *T = undefined,

        pub fn init(state: *lualib.lua_State) Self {
            const _ref = lualib.luaL_ref(state, lualib.LUA_REGISTRYINDEX);
            var res = Self{
                .state = state,
                .ref = _ref,
            };
            return res;
        }

        pub fn destroy(self: *const Self) void {
            _ = lualib.luaL_unref(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
        }

        pub fn clone(self: *const Self) Self {
            _ = lualib.lua_rawgeti(self.state, lualib.LUA_REGISTRYINDEX, self.ref);
            var result = Self.init(self.state);
            result.ptr = self.ptr;
            return result;
        }
    };
}

pub fn ZigCallHelper(comptime FuncType: type) type {
    const info = @typeInfo(FuncType);
    if (info != .Fn) {
        @compileError("ZigCallHelper expects a function type");
    }

    const ReturnType = info.Fn.return_type.?;
    const ArgTypes = std.meta.ArgsTuple(FuncType);
    const result_cnt = if (ReturnType == void) 0 else 1;

    return struct {
        pub const LowLevelHelpers = struct {
            const Self = @This();

            args: ArgTypes = undefined,
            result: ReturnType = undefined,

            pub fn init() Self {
                return Self{};
            }

            pub fn prepareArgs(self: *Self, L: ?*lualib.lua_State) !void {
                // Prepare arguments
                comptime var i = self.args.len - 1;
                inline while (i > -1) : (i -= 1) {
                    if (comptime util.allocateDeallocateHelper(@TypeOf(self.args[i]), false, null, null)) {
                        self.args[i] = util.popResource(@TypeOf(self.args[i]), L.?) catch unreachable;
                    } else {
                        self.args[i] = util.pop(@TypeOf(self.args[i]), L.?) catch unreachable;
                    }
                }
            }

            pub fn call(self: *Self, func: FuncType) !void {
                self.result = @call(.{}, func, self.args);
            }

            fn pushResult(self: *Self, L: ?*lualib.lua_State) !void {
                if (result_cnt > 0) {
                    util.push(L.?, self.result);
                }
            }

            fn destroyArgs(self: *Self, L: ?*lualib.lua_State) !void {
                comptime var i = self.args.len - 1;
                inline while (i > -1) : (i -= 1) {
                    _ = util.allocateDeallocateHelper(@TypeOf(self.args[i]), true, util.getAllocator(L), self.args[i]);
                }
                _ = util.allocateDeallocateHelper(ReturnType, true, util.getAllocator(L), self.result);
            }
        };

        pub fn pushFunctor(state: ?*lualib.lua_State, func: FuncType) !void {
            const func_ptr_as_int = @intCast(c_longlong, @ptrToInt(func));
            lualib.lua_pushinteger(state, func_ptr_as_int);

            const cfun = struct {
                fn helper(_L: ?*lualib.lua_State) callconv(.C) c_int {
                    var f: LowLevelHelpers = undefined;
                    // Prepare arguments from stack
                    f.prepareArgs(_L) catch unreachable;
                    // Get func pointer upvalue as int => convert to func ptr then call
                    var ptr = lualib.lua_tointegerx(_L, lualib.lua_upvalueindex(1), null);
                    f.call(@intToPtr(FuncType, @intCast(usize, ptr))) catch unreachable;
                    // The end
                    f.pushResult(_L) catch unreachable;
                    // Release arguments
                    f.destroyArgs(_L) catch unreachable;
                    return result_cnt;
                }
            }.helper;
            lualib.lua_pushcclosure(state, cfun, 1);
        }
    };
}
