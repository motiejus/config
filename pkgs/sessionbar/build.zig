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

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app.addOptions("build_options", opts);
    app.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    app.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    // AppKit/Foundation re-export libobjc, which only exists on disk as the SDK
    // stub; without this search path the link fails resolving libobjc.A.dylib.
    app.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    app.linkSystemLibrary("objc", .{});
    app.linkFramework("Foundation", .{});
    app.linkFramework("AppKit", .{});
    b.installArtifact(b.addExecutable(.{ .name = "sessionbar", .root_module = app }));

    // The CLI is pure libc: no frameworks, so no SDK paths and no rpath.
    const cli = b.createModule(.{
        .root_source_file = b.path("src/reauth.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli.addOptions("build_options", opts);
    b.installArtifact(b.addExecutable(.{ .name = "gcloud-force-reauth", .root_module = cli }));

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/sys.zig", "src/expiry.zig", "src/reauth.zig" }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addOptions("build_options", opts);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
}
