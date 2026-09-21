const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption(
        []const u8,
        "reauth_path",
        b.option([]const u8, "reauth", "Absolute path to the gcloud-force-reauth binary") orelse
            "gcloud-force-reauth",
    );
    opts.addOption(
        []const u8,
        "gcloud_path",
        b.option([]const u8, "gcloud", "Absolute path to the gcloud binary") orelse "gcloud",
    );

    // Hermetic SDK: -Dsdk= or SDKROOT (which nixpkgs' apple-sdk sets) points at a
    // nix apple-sdk, so zig never shells out to xcrun for /Library/Developer.
    // Deliberately not --sysroot: zig then prefixes the sysroot onto -L as well.
    const sdk = b.option([]const u8, "sdk", "Path to a MacOSX.sdk") orelse
        b.graph.environ_map.get("SDKROOT") orelse
        @panic("no macOS SDK: pass -Dsdk=<MacOSX.sdk> or set SDKROOT");

    const Ctx = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        opts: *std.Build.Step.Options,
        sdk: []const u8,

        fn module(c: @This(), root: []const u8, appkit: bool) *std.Build.Module {
            const m = c.b.createModule(.{
                .root_source_file = c.b.path(root),
                .target = c.target,
                .optimize = c.optimize,
                .link_libc = true,
            });
            m.addOptions("build_options", c.opts);
            if (!appkit) return m;

            m.addSystemFrameworkPath(.{ .cwd_relative = c.b.pathJoin(&.{ c.sdk, "System/Library/Frameworks" }) });
            m.addSystemIncludePath(.{ .cwd_relative = c.b.pathJoin(&.{ c.sdk, "usr/include" }) });
            // AppKit/Foundation re-export libobjc, which exists on disk only as
            // the SDK stub; without this search path the link cannot resolve it.
            m.addLibraryPath(.{ .cwd_relative = c.b.pathJoin(&.{ c.sdk, "usr/lib" }) });
            m.linkSystemLibrary("objc", .{});
            m.linkFramework("CoreFoundation", .{});
            m.linkFramework("Foundation", .{});
            m.linkFramework("AppKit", .{});
            return m;
        }
    };
    const ctx: Ctx = .{ .b = b, .target = target, .optimize = optimize, .opts = opts, .sdk = sdk };

    for ([_]struct { []const u8, []const u8, bool }{
        .{ "sessionbar", "src/main.zig", true },
        // The CLI is pure libc: no frameworks, so no SDK paths at all.
        .{ "gcloud-force-reauth", "src/reauth.zig", false },
    }) |spec| {
        const exe = b.addExecutable(.{ .name = spec[0], .root_module = ctx.module(spec[1], spec[2]) });
        // The SDK -L dir would otherwise become an LC_RPATH, pinning the whole
        // SDK into the runtime closure; nothing is loaded from it at run time.
        exe.each_lib_rpath = false;
        b.installArtifact(exe);
    }

    const test_step = b.step("test", "Run unit tests");
    for ([_]struct { []const u8, bool }{
        .{ "src/sys.zig", false },
        .{ "src/expiry.zig", false },
        .{ "src/reauth.zig", false },
        .{ "src/main.zig", true },
    }) |spec| {
        const t = b.addTest(.{ .root_module = ctx.module(spec[0], spec[1]) });
        t.each_lib_rpath = false;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
