const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cell = struct {
    times_mutated: usize,
    last_mutation: usize,
    species: u8,
};

pub const World = struct {
    cells: []Cell,
    world_size: usize,

    pub fn init(allocator: Allocator, world_size: usize) Allocator.Error!World {
        var cells = try allocator.alloc(Cell, world_size * world_size);
        const bytes = std.mem.sliceAsBytes(cells[0..cells.len]);
        @memset(bytes, 0);
        return World{ .cells = cells, .world_size = world_size };
    }

    pub fn deinit(self: *World, allocator: Allocator) void {
        allocator.free(self.cells);
    }

    pub fn format(self: *const World, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("World size: {0d}x{0d}\n", .{self.world_size});

        for (0..self.world_size) |n| {
            for (self.cells[(self.world_size * n)..(self.world_size * (n + 1))]) |cell| {
                try writer.print("{d: >5}", .{cell.species});
            }
            if (n != self.world_size)
                try writer.print("\n", .{});
        }
    }

    pub fn equals(self: *const World, other: *const World) bool {
        for (0.., self.cells) |i, cell| {
            const other_cell = other.cells[i];

            if (cell.species != other_cell.species or cell.times_mutated != other_cell.times_mutated or cell.last_mutation != other_cell.last_mutation)
                return false;
        }

        return true;
    }
};
