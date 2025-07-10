const std = @import("std");
const zigimg = @import("zigimg");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Image = zigimg.Image;
const color = zigimg.color;

const IterationError = error{IterationError}.IterationError;

const World = @import("world.zig").World;
const Cell = @import("world.zig").Cell;

pub const Simulation = struct {
    world_size: usize,
    world: World,
    new_world: World,
    allocator: Allocator,
    num_species: u8,

    pub fn init(world_size: usize, num_species: u8, allocator: Allocator) !Simulation {
        var world = try World.init(allocator, world_size);
        errdefer world.deinit(allocator);

        var new_world = try World.init(allocator, world_size);
        errdefer new_world.deinit(allocator);

        setup(&world, num_species);

        for (0..world_size * world_size) |_| {
            new_world.cells.appendAssumeCapacity(.{.species = 0, .last_mutation = 0, .times_mutated = 0});
        }

        return Simulation{ .world_size = world_size, .world = world, .new_world = new_world, .allocator = allocator, .num_species = num_species };
    }

    pub fn reset(self: *Simulation) void {
        self.world.cells.clearRetainingCapacity();
        setup(&self.world, self.num_species);

        for (0..self.world_size * self.world_size) |i| {
            self.new_world.cells.set(i, .{.species = 0, .last_mutation = 0, .times_mutated = 0});
        }
    }

    pub fn deinit(self: *Simulation) void {
        self.world.deinit(self.allocator);
        self.new_world.deinit(self.allocator);
    }

    pub fn run(self: *Simulation, max_iterations: usize, allocator: Allocator) !void {
        var current_world = try World.init(allocator, self.world_size);
        defer current_world.deinit(allocator);

        for (self.world.cells.items(.species)) |species| {
            current_world.cells.appendAssumeCapacity(.{.species = species, .last_mutation = 0, .times_mutated = 0});
        }

        try self.run_single(&self.world, &self.new_world, max_iterations, allocator);
        try self.run_threaded(&current_world, &self.new_world, max_iterations, allocator);

        std.debug.assert(self.world.equals(&current_world));

        // if (self.world_size >= 100) {
        //     try self.run_threaded(&self.world, &self.new_world, @min(self.world_size * self.world_size * 100, max_iterations), allocator);
        // } else {
        //     try self.run_single(&self.world, &self.new_world, @min(self.world_size * self.world_size * 100, max_iterations), allocator);
        // }
    }

    pub fn render(self: *const Simulation, image: *Image, strength: f32) !usize {
        const seed = std.crypto.random.int(u64);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var max: usize = 0;
        for (self.world.cells.items(.last_mutation)) |last_mutation| {
            if (last_mutation > max)
                max = last_mutation;
        }

        max += 1;

        var color_list = try self.allocator.alloc(color.Rgba32, max);
        defer self.allocator.free(color_list);

        var iteration_color = color.Hsv{ .hue = @floatFromInt(rand.intRangeAtMost(i32, 0, 360)), .saturation = rand.float(f32), .value = rand.float(f32) };
        for (0..max) |i| {
            color_list[i] = color.Rgba32.from.color(iteration_color.toRgb());

            iteration_color.hue += (2 * rand.float(f32) * strength) - strength;
            iteration_color.saturation += ((2 * rand.float(f32) * strength) - strength) / 360;
            iteration_color.value += ((2 * rand.float(f32) * strength) - strength) / 360;

            iteration_color.hue = @mod(iteration_color.hue + 360.0, 360.0);
            iteration_color.saturation = std.math.clamp(iteration_color.saturation, 0.0, 1.0);
            iteration_color.value = std.math.clamp(iteration_color.value, 0.0, 1.0);
        }

        for (self.world.cells.items(.last_mutation), image.pixels.rgba32) |last_mutation, *pixel| {
            pixel.* = color_list[last_mutation];
        }

        return max - 1;
    }

    fn run_single(self: *const Simulation, current_world: *World, new_world: *World, max_iterations: usize, allocator: Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const arena_alloc = arena.allocator();

        var to_check = std.AutoArrayHashMap(usize, void).init(allocator);
        defer to_check.deinit();

        try to_check.ensureTotalCapacity(self.world_size * self.world_size);

        for (0..self.world_size * self.world_size) |i| {
            try to_check.put(i, {});
        }

        var mutated = true;
        var iterations: usize = 1;

        const stdout = std.io.getStdOut().writer();
        _ = try stdout.write("\n");

        var timer = try std.time.Timer.start();
        var ns_prev: f64 = 0;

        while (mutated and iterations <= max_iterations) : (iterations += 1) {
            @branchHint(std.builtin.BranchHint.likely);

            mutated = try self.run_iteration(current_world, new_world, &to_check, iterations, arena_alloc);

            const temp = current_world.*;
            current_world.* = new_world.*;
            new_world.* = temp;

            _ = arena.reset(.retain_capacity);
            const ns = timer.read();
            const ns_float: f64 = @floatFromInt(ns);
            const iter_float: f64 = @floatFromInt(iterations);
            try stdout.print("\u{1b}[1A\u{1b}[2KIteration: {d: >8}, Durration: {d: >8.3}s, FPS: {d: >9.3}, IPS: {d: >9.3}\n", .{ iterations, ns_float / std.time.ns_per_s, std.time.ns_per_s / (ns_float - ns_prev), (iter_float * std.time.ns_per_s / ns_float) });
            ns_prev = ns_float;
        }
    }

    fn run_threaded(self: *const Simulation, current_world: *World, new_world: *World, max_iterations: usize, allocator: Allocator) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var thread_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = arena_alloc };
        const thread_alloc = thread_allocator.allocator();

        var pool: std.Thread.Pool = undefined;
        const num_threads = std.Thread.getCpuCount() catch 4;
        try pool.init(.{ .allocator = allocator, .n_jobs = num_threads });
        defer pool.deinit();

        var wg: std.Thread.WaitGroup = .{};

        var mutated: u8 = 1;
        var iterations: usize = 1;

        const stdout = std.io.getStdOut().writer();
        _ = try stdout.write("\n");

        var timer = try std.time.Timer.start();
        var ns_prev: f64 = 0;

        while (mutated == 1 and iterations <= max_iterations) : (iterations += 1) {
            @branchHint(std.builtin.BranchHint.likely);

            mutated = 0;
            for (0..self.world_size) |i| {
                pool.spawnWg(&wg, struct {
                    fn run(sim: *const Simulation, _current_world: *World, _new_world: *World, _iteration: usize, _allocator: Allocator, _chunk_start: usize, _chunk_size: usize, _mutated: *u8) void {
                        const result = sim.run_iteration_chunk(_current_world, _new_world, _iteration, _allocator, _chunk_start, _chunk_size) catch 2;
                        _ = @cmpxchgStrong(u8, _mutated, 0, result, .monotonic, .monotonic);
                    }
                }.run, .{ self, current_world, new_world, iterations, thread_alloc, i * self.world_size, self.world_size, &mutated });
            }

            wg.wait();
            wg.reset();

            const temp = current_world.*;
            current_world.* = new_world.*;
            new_world.* = temp;

            _ = arena.reset(.retain_capacity);
            const ns = timer.read();
            const ns_float: f64 = @floatFromInt(ns);
            const iter_float: f64 = @floatFromInt(iterations);
            try stdout.print("\u{1b}[1A\u{1b}[2KIteration: {d: >8}, Durration: {d: >8.3}s, FPS: {d: >9.3}, IPS: {d: >9.3}\n", .{ iterations, ns_float / std.time.ns_per_s, std.time.ns_per_s / (ns_float - ns_prev), (iter_float * std.time.ns_per_s / ns_float) });
            ns_prev = ns_float;
        }
    }

    fn run_iteration(self: *const Simulation, current_world: *World, new_world: *World, to_check: *std.AutoArrayHashMap(usize, void), iteration: usize, allocator: Allocator) !bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = arena.allocator();

        var to_sleep = std.AutoHashMap(usize, void).init(arena_alloc);
        var to_wake = std.AutoHashMap(usize, void).init(arena_alloc);

        var sleep = false;

        var mutated = false;

        const species_bucket = try arena_alloc.alloc(u8, self.num_species);
        for (to_check.keys()) |i| {
            const new_species = self.getNewSpecies(current_world.cells.items(.species), i, species_bucket, iteration, &sleep);

            const current_cell = current_world.cells.get(i);

            if (sleep) {
                try to_sleep.put(i, {});
            }

            new_world.cells.items(.species)[i] = new_species;
            if (current_cell.species != new_species) {
                mutated = true;

                new_world.cells.items(.times_mutated)[i] = current_cell.times_mutated + 1;
                new_world.cells.items(.last_mutation)[i] = iteration;

                inline for (getSurrounding(@intCast(self.world_size), i)) |n| {
                    try to_wake.put(n, {});
                }
                try to_wake.put(i, {});
            } else {
                new_world.cells.items(.times_mutated)[i] = current_cell.times_mutated;
                new_world.cells.items(.last_mutation)[i] = current_cell.last_mutation;
            }
        }

        var sleep_iter = to_sleep.keyIterator();

        while (sleep_iter.next()) |k| {
            _ = to_check.swapRemove(k.*);
        }

        var wake_iter = to_wake.keyIterator();

        while(wake_iter.next()) |k| {
            try to_check.put(k.*, {});
        }

        return mutated;
    }

    fn run_iteration_chunk(self: *const Simulation, current_world: *World, new_world: *World, iteration: usize, allocator: Allocator, chunk_start: usize, chunk_size: usize) !u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);

        const arena_alloc = arena.allocator();
        
        var mutated: u8 = 0;

        var sleep = false;

        const species_bucket = try arena_alloc.alloc(u8, self.num_species);
        for (chunk_start..(chunk_size + chunk_start)) |i| {
            const new_species = self.getNewSpecies(current_world.cells.items(.species), i, species_bucket, iteration, &sleep);

            const current_cell = current_world.cells.get(i);

            new_world.cells.items(.species)[i] = new_species;
            if (current_cell.species != new_species) {
                mutated = 1;

                new_world.cells.items(.times_mutated)[i] = current_cell.times_mutated + 1;
                new_world.cells.items(.last_mutation)[i] = iteration;

            } else {
                new_world.cells.items(.times_mutated)[i] = current_cell.times_mutated;
                new_world.cells.items(.last_mutation)[i] = current_cell.last_mutation;
            }
        }

        return mutated;
    }

    inline fn getNewSpecies(self: *const Simulation, cells: []u8, index: usize, bucket: []u8, seed: usize, sleep: *bool) u8 {
        @memset(bucket, 0);

        sleep.* = false;

        const world_size: i128 = @intCast(self.world_size);
        const surrounding = getSurrounding(world_size, index);

        bucket[cells[surrounding[0]]] += 1;
        bucket[cells[surrounding[1]]] += 1;
        bucket[cells[surrounding[2]]] += 1;

        bucket[cells[surrounding[3]]] += 1;
        bucket[cells[surrounding[4]]] += 1;

        bucket[cells[surrounding[5]]] += 1;
        bucket[cells[surrounding[6]]] += 1;
        bucket[cells[surrounding[7]]] += 1;

        var prng = std.Random.Xoshiro256.init((cells[index] ^ seed) * 1099511628211);
        const test_rand = prng.random();

        var max_idx: usize = 0;
        var max_count: u8 = 0;
        for (0.., bucket) |n, count| {
            if (max_count < count) {
                max_idx = n;
                max_count = count;
            } else if (max_count == count and test_rand.boolean()) {
                max_idx = n;
                max_count = count;
            }
        }

        if (max_count >= 5)
            sleep.* = true;

        return @intCast(max_idx);
    }

    inline fn getSurrounding(world_size: i128, index: usize) [8]usize {
        const x: i128 = @intCast(@divFloor(index, world_size));
        const y: i128 = @intCast(@mod(index, world_size));

        return .{
            @intCast(@mod(x - 1, world_size) * world_size + @mod(y - 1, world_size)),
            @intCast(@mod(x - 1, world_size) * world_size + y),
            @intCast(@mod(x - 1, world_size) * world_size + @mod(y + 1, world_size)),

            @intCast(x * world_size + @mod(y - 1, world_size)),
            @intCast(x * world_size + @mod(y + 1, world_size)),

            @intCast(@mod(x + 1, world_size) * world_size + @mod(y - 1, world_size)),
            @intCast(@mod(x + 1, world_size) * world_size + y),
            @intCast(@mod(x + 1, world_size) * world_size + @mod(y + 1, world_size)),
        };
    }

    inline fn setup(world: *World, num_species: u8) void {
        const seed = std.crypto.random.int(u64);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        for (0..world.world_size * world.world_size) |_| {
            const species = rand.intRangeAtMost(u8, 0, num_species - 1);
            world.cells.appendAssumeCapacity(.{.species = species, .last_mutation = 0, .times_mutated = 0});
        }
    }

    inline fn setup_consistent(world: *World, num_species: u8) void {
        for (0..world.world_size * world.world_size) |i| {
            const x: i128 = @intCast(@divFloor(i, world.world_size));
            const species: u8 = @intCast(@mod(x, num_species));
            world.cells.appendAssumeCapacity(.{.species = species, .last_mutation = 0, .times_mutated = 0});
        }
    }
};
