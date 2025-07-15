const std = @import("std");
const zigimg = @import("zigimg");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Simulation = @import("sim.zig").Simulation;
const World = @import("world.zig").World;

const c = @cImport({
    @cInclude("time.h");
});

var config = struct {
    world_size: usize = 500,
    max_iterations: usize = 0,
    num_species: u8 = 5,
    mut_strength: f32 = 1.0,
    batch: std.meta.Int(.signed, @typeInfo(usize).int.bits + 1) = 0,

    alloc: ?Allocator = null,
}{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    config.alloc = allocator;

    var r = try cli.AppRunner.init(allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "",
            .options = try r.allocOptions(&.{
                cli.Option{
                    .long_name = "world_size",
                    .short_alias = 'w',
                    .value_ref = r.mkRef(&config.world_size),
                    .help = "Square world size of the simulation. Default is 500x500.",
                },
                cli.Option{
                    .long_name = "max_iterations",
                    .short_alias = 'i',
                    .value_ref = r.mkRef(&config.max_iterations),
                    .help = "Max number of iterations before the simulation is forcibly stopped, 0 means run indefinitely. Default is 0.",
                },
                cli.Option{
                    .long_name = "num_species",
                    .short_alias = 'n',
                    .value_ref = r.mkRef(&config.num_species),
                    .help = "The number of species in the simulation. Default is 5.",
                },
                cli.Option{
                    .long_name = "mut_str",
                    .short_alias = 'm',
                    .value_ref = r.mkRef(&config.mut_strength),
                    .help = "The mutation strenght of the colors. Default is 1.0",
                },
                cli.Option{
                    .long_name = "batch",
                    .short_alias = 'b',
                    .value_ref = r.mkRef(&config.batch),
                    .help = "Number of batches to run, negative numbers mean maximum number of iterations. Default is 0.",
                },
            }),
            .target = .{
                .action = .{
                    .exec = runGenesheep,
                },
            },
        },
    };

    try r.run(&app);

}

fn runGenesheep() !void {
    const max_iterations: usize = blk: {
        if (config.max_iterations == 0) {
            break :blk std.math.maxInt(usize);
        }
        break :blk config.max_iterations;
    };

    const batch: usize = blk: {
        if (config.batch <= 0) {
            break :blk std.math.maxInt(usize);
        }
        break :blk @intCast(config.batch);
    };

    const sim_run_buffer = sim_run_buf: {
        const bitset_buffer = blk: {
            const num_bits = config.world_size * config.world_size;
            const numerator = num_bits + (@typeInfo(std.DynamicBitSetUnmanaged.MaskInt).int.bits - 1);
            const usize_per_bitset = (numerator / @typeInfo(std.DynamicBitSetUnmanaged.MaskInt).int.bits) + 1;
            break :blk (usize_per_bitset * 8) * 3;
        };

        const indices_buffer = config.world_size * config.world_size * (@typeInfo(usize).int.bits / 8);
        const species_buffer = config.num_species;

        break :sim_run_buf bitset_buffer + indices_buffer + species_buffer;
    };

    const buffer_size = sim_run_buffer;

    const allocator = config.alloc.?;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var fixed_buffer = std.heap.FixedBufferAllocator.init(buffer);
    const buffer_alloc = fixed_buffer.allocator();

    var sim = try Simulation.init(config.world_size, config.num_species, allocator);
    defer sim.deinit(allocator);

    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write("\u{1b}[?25l");
    defer stdout.print("\u{1b}[?25h", .{}) catch {};

    var batch_num: usize = 0;

    while (true) : (batch_num += 1) {
        if (batch <= batch_num) {
            @branchHint(.unlikely);
            break;
        }

        if (sim.run(max_iterations, buffer_alloc)) {
            @branchHint(.likely);
            var image = try zigimg.Image.create(allocator, config.world_size, config.world_size, .rgba32);
            defer image.deinit();

            try sim.render(&image, config.mut_strength, allocator);

            const time = c.time(null);
            const local_time = c.localtime(&time);

            const file_name_base = try format_time(local_time, sim.total_iterations, allocator);
            defer allocator.free(file_name_base);

            const image_file_name = try std.fmt.allocPrint(allocator, "{s}.png", .{file_name_base});
            defer allocator.free(image_file_name);

            const json_file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{file_name_base});
            defer allocator.free(json_file_name);

            try image.writeToFilePath(image_file_name, .{ .png = .{} });
            try stdout.print("Saved image {s}\n", .{image_file_name});

            const json_file = try std.fs.cwd().createFile(json_file_name, .{});
            defer json_file.close();

            _ = try std.json.stringify(sim, .{}, json_file.writer());
            try stdout.print("Saved simulation data {s}\n", .{json_file_name});
        } else |err| {
            try stdout.print("Error: {any}\n", .{err});
        }

        std.debug.assert(fixed_buffer.end_index == 0);

        sim.reset();
    }
}

fn format_time(local_time: [*c]c.struct_tm, iterations: usize, allocator: std.mem.Allocator) ![]u8 {
    const year: u16 = @intCast(local_time.*.tm_year + 1900);
    const month: u8 = @intCast(local_time.*.tm_mon);
    const day: u8 = @intCast(local_time.*.tm_mday);
    const hour: u8 = @intCast(local_time.*.tm_hour);
    const minute: u8 = @intCast(local_time.*.tm_min);
    const second: u8 = @intCast(local_time.*.tm_sec);

    return std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{:0>2} {:0>2}-{:0>2}-{d:0>2}_i{d}", .{ year, month, day, hour, minute, second, iterations });
}
