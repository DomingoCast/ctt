const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // External dependencies
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const vaxis_mod = vaxis_dep.module("vaxis");
    const zqlite_mod = zqlite_dep.module("zqlite");
    const clap_mod = clap_dep.module("clap");

    // --- Hexagonal module graph ---

    // domain: no imports
    const domain = b.addModule("domain", .{
        .root_source_file = b.path("src/domain/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // application: imports domain
    const application = b.addModule("application", .{
        .root_source_file = b.path("src/application/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    application.addImport("domain", domain);

    // infra_sqlite: imports domain, zqlite
    const infra_sqlite = b.addModule("infra_sqlite", .{
        .root_source_file = b.path("src/infra/outbound/sqlite/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_sqlite.addImport("domain", domain);
    infra_sqlite.addImport("zqlite", zqlite_mod);

    // infra_git: imports domain
    const infra_git = b.addModule("infra_git", .{
        .root_source_file = b.path("src/infra/outbound/git/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_git.addImport("domain", domain);

    // infra_gh: imports domain
    const infra_gh = b.addModule("infra_gh", .{
        .root_source_file = b.path("src/infra/outbound/gh/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_gh.addImport("domain", domain);

    // infra_linear: imports domain
    const infra_linear = b.addModule("infra_linear", .{
        .root_source_file = b.path("src/infra/outbound/linear/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_linear.addImport("domain", domain);

    // infra_config: imports domain
    const infra_config = b.addModule("infra_config", .{
        .root_source_file = b.path("src/infra/outbound/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_config.addImport("domain", domain);

    // infra_cli: imports domain, application, clap
    const infra_cli = b.addModule("infra_cli", .{
        .root_source_file = b.path("src/infra/inbound/cli/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_cli.addImport("domain", domain);
    infra_cli.addImport("application", application);
    infra_cli.addImport("clap", clap_mod);

    // infra_mcp: imports domain, application
    const infra_mcp = b.addModule("infra_mcp", .{
        .root_source_file = b.path("src/infra/inbound/mcp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_mcp.addImport("domain", domain);
    infra_mcp.addImport("application", application);

    // infra_tui: imports domain, application, vaxis
    const infra_tui = b.addModule("infra_tui", .{
        .root_source_file = b.path("src/infra/inbound/tui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    infra_tui.addImport("domain", domain);
    infra_tui.addImport("application", application);
    infra_tui.addImport("vaxis", vaxis_mod);
    infra_tui.addImport("infra_config", infra_config);

    // --- Executable ---
    const exe = b.addExecutable(.{
        .name = "ctt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "domain", .module = domain },
                .{ .name = "application", .module = application },
                .{ .name = "infra_sqlite", .module = infra_sqlite },
                .{ .name = "infra_git", .module = infra_git },
                .{ .name = "infra_gh", .module = infra_gh },
                .{ .name = "infra_linear", .module = infra_linear },
                .{ .name = "infra_config", .module = infra_config },
                .{ .name = "infra_cli", .module = infra_cli },
                .{ .name = "infra_mcp", .module = infra_mcp },
                .{ .name = "infra_tui", .module = infra_tui },
            },
        }),
    });
    b.installArtifact(exe);

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_]*std.Build.Module{
        domain,
        application,
        infra_sqlite,
        infra_git,
        infra_gh,
        infra_linear,
        infra_config,
        infra_cli,
        infra_mcp,
        infra_tui,
    };

    for (test_modules) |mod| {
        const t = b.addTest(.{
            .root_module = mod,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
