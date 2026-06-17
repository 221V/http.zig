const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    //const optimize = b.standardOptimizeOption(.{}); // -O Debug
    const optimize = std.builtin.OptimizeMode.ReleaseFast; // -O ReleaseFast

    const dep_opts = .{ .target = target, .optimize = optimize };
    const metrics_module = b.dependency("metrics", dep_opts).module("metrics");
    const websocket_module = b.dependency("websocket", dep_opts).module("websocket");

    const httpz_module = b.addModule("httpz", .{
        .root_source_file = b.path("src/httpz.zig"),
        .imports = &.{
            .{ .name = "metrics", .module = metrics_module },
            .{ .name = "websocket", .module = websocket_module },
        },
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "httpz_blocking", false);
        httpz_module.addOptions("build", options);
    }

    {
        const enable_tsan = b.option(bool, "tsan", "Enable ThreadSanitizer");
        const test_filter = b.option([]const []const u8, "test-filter", "Filters for test: specify multiple times for multiple filters");
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/httpz.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = enable_tsan,
            }),
            .filters = test_filter orelse &.{},
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        tests.linkLibC();
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        {
            const options = b.addOptions();
            options.addOption(bool, "httpz_blocking", force_blocking);
            tests.root_module.addOptions("build", options);
        }
        {
            const options = b.addOptions();
            options.addOption(bool, "websocket_blocking", force_blocking);
            websocket_module.addOptions("build", options);
        }

        tests.root_module.addImport("metrics", metrics_module);
        tests.root_module.addImport("websocket", websocket_module);
        const run_test = b.addRunArtifact(tests);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "examples_http/01_basic.zig", .name = "example_1" },
        .{ .file = "examples_http/02_handler.zig", .name = "example_2" },
        .{ .file = "examples_http/03_dispatch.zig", .name = "example_3" },
        .{ .file = "examples_http/04_action_context.zig", .name = "example_4" },
        .{ .file = "examples_http/05_request_takeover.zig", .name = "example_5" },
        .{ .file = "examples_http/06_middleware.zig", .name = "example_6" },
        .{ .file = "examples_http/07_advanced_routing.zig", .name = "example_7" },
        .{ .file = "examples_http/09_shutdown.zig", .name = "example_9", .libc = true },
        
        .{ .file = "examples_ws/01_websocket.zig", .name = "example_ws_1" },
    };

    {
        for (examples) |ex| {
            const exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(ex.file),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            exe.root_module.addImport("httpz", httpz_module);
            exe.root_module.addImport("metrics", metrics_module);
            if (ex.libc) {
                exe.linkLibC();
            }
            //b.installArtifact(exe);
            const install_artifact = b.addInstallBinFile(exe.getEmittedBin(), b.fmt("../../{s}", .{ ex.name }) ); // to project root
            b.getInstallStep().dependOn(&install_artifact.step);
            
            const build_step = b.step(b.fmt("{s}", .{ ex.name }), b.fmt("Build httpz example ({s})", .{ ex.name }));
            build_step.dependOn(&install_artifact.step);
            
            const run_artifact = b.addRunArtifact(exe);
            run_artifact.step.dependOn(&install_artifact.step);
            
            const run_step = b.step(b.fmt("run_{s}", .{ ex.name }), b.fmt("Run httpz example ({s})", .{ ex.name }));
            run_step.dependOn(&install_artifact.step);
            run_step.dependOn(&run_artifact.step);

            //const run_cmd = b.addRunArtifact(exe);
            //run_cmd.step.dependOn(b.getInstallStep());
            //if (b.args) |args| {
            //    run_cmd.addArgs(args);
            //}

            //const run_step = b.step(ex.name, ex.file);
            //run_step.dependOn(&run_cmd.step);
        }
    }
}
