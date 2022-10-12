const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,
registered_types: std.StringArrayHashMap([]const u8),

pub fn init(allocator: std.mem.Allocator) Self {
    const registered_types = std.StringArrayHashMap([]const u8).init(allocator);

    return .{
        .allocator = allocator,
        .registered_types = registered_types,
    };
}

pub fn destroy(self: *Self) void {
    self.registered_types.clearAndFree();
}
