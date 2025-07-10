const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cell = struct {
    times_mutated: usize,
    last_mutation: usize,
    species: u8,
};

pub const World = struct {
    cells: std.MultiArrayList(Cell),
    world_size: usize,

    pub fn init(allocator: Allocator, world_size: usize) Allocator.Error!World {
        var cells = std.MultiArrayList(Cell){};

        try cells.ensureTotalCapacity(allocator, world_size * world_size);

        return World{ .cells = cells, .world_size = world_size };
    }

    pub fn deinit(self: *World, allocator: Allocator) void {
        self.cells.deinit(allocator);
    }

    pub fn format(self: *const World, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("World size: {0d}x{0d}\n", .{self.world_size});

        const species = self.cells.items(.species);

        for (0..self.world_size) |n| {
            for (species[(self.world_size * n)..(self.world_size * (n + 1))]) |specie| {
                try writer.print("{d: >5}", .{specie});
            }
            if (n != self.world_size)
                try writer.print("\n", .{});
        }
    }

    pub fn equals(self: *const World, other: *const World) bool {
        const Field = std.MultiArrayList(Cell).Field;

        const self_slice = self.cells.slice();

        const self_ptrs = self.cells.slice().ptrs;
        const other_ptrs = other.cells.slice().ptrs;

        for (0..self_slice.len) |i| {
            if (self_ptrs[@intFromEnum(Field.species)][i] != other_ptrs[@intFromEnum(Field.species)][i] 
                or self_ptrs[@intFromEnum(Field.last_mutation)][i] != other_ptrs[@intFromEnum(Field.last_mutation)][i]
                or self_ptrs[@intFromEnum(Field.times_mutated)][i] != other_ptrs[@intFromEnum(Field.times_mutated)][i]
            ) return false;
        }

        return true;
    }
};
