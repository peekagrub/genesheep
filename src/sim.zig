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
    num_species: u8,

    pub fn init(world_size: usize, num_species: u8, allocator: Allocator) !Simulation {
        var world = try World.init(allocator, world_size);
        errdefer world.deinit(allocator);

        setup(&world, num_species);

        return Simulation{ .world_size = world_size, .world = world, .num_species = num_species };
    }

    pub fn reset(self: *Simulation) void {
        self.world.cells.clearRetainingCapacity();
        setup(&self.world, self.num_species);
    }

    pub fn deinit(self: *Simulation, allocator: Allocator) void {
        self.world.deinit(allocator);
    }

    pub fn run(self: *Simulation, max_iterations: usize, allocator: Allocator) !void {
        try self.run_single(&self.world, max_iterations, allocator);
    }

    pub fn render(self: *const Simulation, image: *Image, strength: f32, allocator: Allocator) !usize {
        const seed = std.crypto.random.int(u64);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var max: usize = 0;
        for (self.world.cells.items(.last_mutation)) |last_mutation| {
            if (last_mutation > max)
                max = last_mutation;
        }

        max += 1;

        var color_list = try allocator.alloc(color.Rgba32, max);
        defer allocator.free(color_list);

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

    fn run_single(
        self: *const Simulation,
        current_world: *World,
        max_iterations: usize,
        allocator: Allocator
    ) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const arena_alloc = arena.allocator();

        var to_check = try std.DynamicBitSetUnmanaged.initFull(allocator, self.world_size * self.world_size);
        defer to_check.deinit(allocator);

        var to_sleep = try std.DynamicBitSetUnmanaged.initFull(allocator, to_check.capacity());
        defer to_sleep.deinit(allocator);

        var to_wake = try std.DynamicBitSetUnmanaged.initEmpty(allocator, to_check.capacity());
        defer to_wake.deinit(allocator);

        const seed = std.crypto.random.int(usize);
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var mutated = true;
        var iterations: usize = 1;

        const stdout = std.io.getStdOut().writer();
        _ = try stdout.write("\n");

        var timer = try std.time.Timer.start();
        var ns_prev: f64 = 0;

        while (mutated and iterations <= max_iterations) : (iterations += 1) {
            @branchHint(.likely);

            mutated = try self.run_iteration(current_world, &to_check, &to_sleep, &to_wake, iterations, random, arena_alloc);

            to_check.setIntersection(to_sleep);
            to_check.setUnion(to_wake);

            to_sleep.setAll();
            to_wake.unsetAll();

            _ = arena.reset(.retain_capacity);
            const ns = timer.read();
            const ns_float: f64 = @floatFromInt(ns);
            const iter_float: f64 = @floatFromInt(iterations);
            try stdout.print("\u{1b}[1A\u{1b}[2KIteration: {d: >8}, Durration: {d: >8.3}s, FPS: {d: >10.3}, IPS: {d: >10.3}\n", .{ iterations, ns_float / std.time.ns_per_s, std.time.ns_per_s / (ns_float - ns_prev), (iter_float * std.time.ns_per_s / ns_float) });
            ns_prev = ns_float;
        }
    }

    fn run_iteration(
        self: *const Simulation,
        current_world: *World,
        to_check: *std.DynamicBitSetUnmanaged,
        to_sleep: *std.DynamicBitSetUnmanaged,
        to_wake: *std.DynamicBitSetUnmanaged,
        iteration: usize,
        random: std.Random,
        allocator: Allocator
    ) !bool {
        var sleep = false;
        var mutated = false;

        const species = current_world.cells.items(.species);

        const species_bucket = try allocator.alloc(u8, self.num_species);

        const count = to_check.count();
        const random_indices = try allocator.alloc(usize, count);

        var bit_iter = to_check.iterator(.{});

        var idx: usize = 0;
        while (bit_iter.next()) |i| : (idx += 1) {
            random_indices[idx] = i;
        }

        random.shuffle(usize, random_indices);

        for (random_indices) |i| {
            @branchHint(.likely);

            const new_species = self.getNewSpecies(species, i, species_bucket, random, &sleep);

            if (sleep) {
                to_sleep.unset(i);
            }

            if (species[i] != new_species) {
                mutated = true;

                species[i] = new_species;
                current_world.cells.items(.times_mutated)[i] += 1;
                current_world.cells.items(.last_mutation)[i] = iteration;

                inline for (getSurrounding(self.world_size, i)) |n| {
                    to_wake.set(n);
                }
            }
        }

        return mutated;
    }

    fn getNewSpecies(self: *const Simulation, cells: []u8, index: usize, bucket: []u8, random: std.Random, sleep: *bool) u8 {
        @memset(bucket, 0);

        sleep.* = false;

        const surrounding = getSurrounding(@intCast(self.world_size), index);

        bucket[cells[surrounding[0]]] += 1;
        bucket[cells[surrounding[1]]] += 1;
        bucket[cells[surrounding[2]]] += 1;

        bucket[cells[surrounding[3]]] += 1;
        bucket[cells[surrounding[4]]] += 1;

        bucket[cells[surrounding[5]]] += 1;
        bucket[cells[surrounding[6]]] += 1;
        bucket[cells[surrounding[7]]] += 1;

        var max_idx: usize = 0;
        var max_count: u8 = 0;
        for (0.., bucket) |n, count| {
            if (max_count < count) {
                max_idx = n;
                max_count = count;
            } else if (max_count == count and random.int(i8) >= 0) {
                max_idx = n;
                max_count = count;
            }
        }

        if (max_count >= 5)
            sleep.* = true;

        return @intCast(max_idx);
    }

    fn getSurrounding(world_size: usize, index: usize) [8]usize {
        const x = @divFloor(index, world_size);
        const y = @mod(index, world_size);

        return .{
            @mod(x + world_size - 1, world_size) * world_size + @mod(y + world_size - 1, world_size),
            @mod(x + world_size - 1, world_size) * world_size + y,
            @mod(x + world_size - 1, world_size) * world_size + @mod(y + 1, world_size),

            x * world_size + @mod(y + world_size - 1, world_size),
            x * world_size + @mod(y + 1, world_size),

            @mod(x + 1, world_size) * world_size + @mod(y + world_size - 1, world_size),
            @mod(x + 1, world_size) * world_size + y,
            @mod(x + 1, world_size) * world_size + @mod(y + 1, world_size),
        };
    }

    inline fn setup(world: *World, num_species: u8) void {
        const seed = std.crypto.random.int(u64);
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        for (0..world.world_size * world.world_size) |_| {
            const species = rand.uintLessThan(u8, num_species);
            world.cells.appendAssumeCapacity(.{.species = species, .last_mutation = 0, .times_mutated = 0});
        }
    }
};
