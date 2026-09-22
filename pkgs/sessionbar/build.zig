const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption(
        []const u8,
        "gcloud_path",
        b.option([]const u8, "gcloud", "Absolute path to the gcloud binary") orelse "gcloud",
    );
    // Source of truth is OktaAuthServer in
    // /Library/Managed Preferences/com.jamf.connect.plist, pinned here rather
    // than read at run time.
    opts.addOption(
        []const u8,
        "okta_host",
        b.option([]const u8, "okta-host", "Okta tenant host for the sign-out hop") orelse
            "paloaltonetworks.okta.com",
    );
    opts.addOption(
        []const u8,
        "okta_app",
        b.option([]const u8, "okta-app", "Okta app id of the Google SAML tile") orelse
            "exk1tyqe5nFkbXBBj1t7",
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

    const exe = b.addExecutable(.{ .name = "sessionbar", .root_module = ctx.module("src/main.zig", true) });
    // The SDK -L dir would otherwise become an LC_RPATH, pinning the whole SDK
    // into the runtime closure; nothing is loaded from it at run time.
    exe.each_lib_rpath = false;
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    for ([_]struct { []const u8, bool }{
        // sys.zig has no target of its own: expiry.zig imports it, so a test
        // build rooted there already runs its tests.
        .{ "src/expiry.zig", false },
        // Listed on its own: a test build analyses only what its tests reach,
        // so rooting at main.zig would silently skip every test in here.
        .{ "src/flow.zig", true },
        .{ "src/main.zig", true },
    }) |spec| {
        const t = b.addTest(.{ .root_module = ctx.module(spec[0], spec[1]) });
        t.each_lib_rpath = false;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
