//! AOSC-specific compiler extensions
//!
//! Author: xtex <xtex@astrafall.org>

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.aosc);

const builtin = @import("builtin");

const Compilation = @import("Compilation.zig");
const Package = @import("Package.zig");

const EnvironmentKind = enum(u8) { normal, autobuild };

var env_kind: std.atomic.Value(EnvironmentKind) = .init(.normal);

pub fn getEnvKind() EnvironmentKind {
    return env_kind.load(.acquire);
}

pub fn init(arena: Allocator, environ: std.process.Environ) void {
    log.debug("AOSC extension initialization", .{});
    const detected_env = detectEnvKind(environ) catch |err| kind: {
        log.err("failed to detect environment kind: {t}", .{err});
        break :kind .normal;
    };
    env_kind.store(detected_env, .release);

    if (detected_env == .autobuild) {
        parseFlags(arena, environ) catch |err| log.err("failed to parse AB mode flags: {t}", .{err});
        log.debug("Parsed options: {any}\n", .{options});
    }
}

fn detectEnvKind(environ: std.process.Environ) !EnvironmentKind {
    const abbuild = environ.containsUnemptyConstant("ABBUILD");
    return if (abbuild) .autobuild else .normal;
}

var options: struct {
    check: bool = true,
    check_module_target: bool = true,
    check_module_optimization: bool = true,
    check_module_strip: bool = true,
    check_llvm: bool = true,
    check_incr: bool = true,
    check_lto: bool = true,
    always_native_dirs: bool = true,
} = .{};

fn parseFlags(arena: Allocator, environ: std.process.Environ) !void {
    const flags_str = environ.getAlloc(arena, "ZIG_AOSC_FLAGS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer arena.free(flags_str);
    var flags_it = std.mem.tokenizeScalar(u8, flags_str, ' ');
    while (flags_it.next()) |flag| {
        if (std.mem.eql(u8, flag, "no-sanity-check")) {
            @atomicStore(bool, &options.check, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-any-target")) {
            @atomicStore(bool, &options.check_module_target, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-any-opt")) {
            @atomicStore(bool, &options.check_module_optimization, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-strip")) {
            @atomicStore(bool, &options.check_module_strip, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-no-llvm")) {
            @atomicStore(bool, &options.check_llvm, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-incr")) {
            @atomicStore(bool, &options.check_incr, false, .release);
        } else if (std.mem.eql(u8, flag, "allow-any-lto")) {
            @atomicStore(bool, &options.check_lto, false, .release);
        } else if (std.mem.eql(u8, flag, "no-always-native-dirs")) {
            @atomicStore(bool, &options.always_native_dirs, false, .release);
        } else {
            log.err("unknown flag: {s}", .{flag});
            return error.UnknownABFlag;
        }
    }
}

pub fn checkZcu(zcu: *Compilation) error{OutOfMemory}!bool {
    if (getEnvKind() == .normal) return true;
    if (!@atomicLoad(bool, &options.check, .acquire)) return true;

    const gpa = zcu.gpa;
    var ok = true;

    if (zcu.root_mod.root.root == .zig_lib) {
        log.debug("skipping JIT ZCU", .{});
        return true;
    }

    if (@atomicLoad(bool, &options.check_llvm, .acquire)) {
        if (!zcu.config.use_llvm) {
            ok = false;
            log.err("ZCU '{s}' does not use LLVM", .{zcu.root_name});
        }
        if (!zcu.config.use_lld) {
            ok = false;
            log.err("ZCU '{s}' does not use LLD", .{zcu.root_name});
        }
    }

    if (@atomicLoad(bool, &options.check_incr, .acquire)) {
        if (zcu.config.incremental) {
            ok = false;
            log.err("ZCU '{s}' uses incremental compilation", .{zcu.root_name});
        }
    }

    if (@atomicLoad(bool, &options.check_lto, .acquire)) {
        if (zcu.config.lto != .thin) {
            ok = false;
            log.err("ZCU '{s}' uses '{t}' LTO", .{ zcu.root_name, zcu.config.lto });
        }
    }

    var modules: std.AutoArrayHashMapUnmanaged(*Package.Module, void) = .empty;
    defer modules.deinit(gpa);
    try modules.ensureUnusedCapacity(gpa, 32);
    modules.putAssumeCapacityNoClobber(zcu.root_mod, {});
    var mod_index: usize = 0;
    while (mod_index < modules.count()) : (mod_index += 1) {
        const mod = modules.keys()[mod_index];

        for (mod.deps.values()) |mod_dep| {
            try modules.put(gpa, mod_dep, {});
        }

        const mod_fqn = mod.fully_qualified_name;
        log.debug("checking module sanity '{s}'", .{mod_fqn});
        if (@atomicLoad(bool, &options.check_module_target, .acquire)) check_target: {
            const mod_target = &mod.resolved_target.result;
            if (mod_target.os.tag != .linux) {
                ok = false;
                log.err("target OS of module '{s}' is not linux but {t}", .{ mod_fqn, mod_target.os.tag });
            }
            if (mod_target.ofmt != .elf) {
                ok = false;
                log.err("target object format of module '{s}' is not elf but {t}", .{ mod_fqn, mod_target.ofmt });
            }
            if (mod_target.abi != builtin.abi) {
                ok = false;
                log.err("target ABI of module '{s}' is not {t} but {t}", .{ mod_fqn, builtin.abi, mod_target.abi });
            }
            if (mod_target.cpu.arch != builtin.cpu.arch) {
                ok = false;
                log.err("target architecture of module '{s}' is not {t} but {t}", .{ mod_fqn, builtin.cpu.arch, mod_target.cpu.arch });
                break :check_target;
            }
            if (mod_target.cpu.model != builtin.cpu.model) {
                log.warn("target CPU model of module '{s}' is not '{s}' but '{s}'", .{ mod_fqn, builtin.cpu.model.name, mod_target.cpu.model.name });
            }
            if (!mod_target.cpu.features.eql(builtin.cpu.features)) {
                ok = false;

                log.err("target CPU feature set of module '{s}' is incorrect", .{mod_fqn});
                const all_features = builtin.cpu.arch.allFeaturesList();
                diff_features: for (all_features, 0..) |feature, index_usize| {
                    const index: std.Target.Cpu.Feature.Set.Index = @intCast(index_usize);
                    const is_enabled = mod_target.cpu.features.isEnabled(index);
                    const is_expected = builtin.cpu.features.isEnabled(index);
                    if (is_enabled == is_expected) continue :diff_features;

                    if (is_expected)
                        log.err("hint: should +{s} ({s})", .{ feature.name, feature.description })
                    else
                        log.err("hint: should -{s} ({s})", .{ feature.name, feature.description });
                }
            }
        }
        if (@atomicLoad(bool, &options.check_module_optimization, .acquire)) {
            if (mod.optimize_mode != builtin.mode) {
                ok = false;
                log.err("optimization mode of module '{s}' is not {t} but {t}", .{ mod_fqn, builtin.mode, mod.optimize_mode });
            }
        }
        if (@atomicLoad(bool, &options.check_module_strip, .acquire)) {
            if (mod.strip) {
                ok = false;
                log.err("module '{s}' is stripped", .{mod_fqn});
            }
        }
    }

    return ok;
}

pub fn cmd(arena: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) std.debug.panic(
        \\Usage: zig aosc [command]
        \\
        \\    AOSC extension module
        \\
        \\Commands:
        \\  print-target     Print target query for packaging
        \\  print-cpu        Print target CPU query for packaging
        \\  print-opt        Print target optimization mode for packaging
        \\
    , .{});
    _ = arena;

    if (std.mem.eql(u8, args[0], "print-target")) {
        try std.Io.File.stdout().writeStreamingAll(io, @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi));
    } else if (std.mem.eql(u8, args[0], "print-cpu")) {
        const cpu_str = comptime cpu_str: {
            var cpu_str = builtin.cpu.model.name;
            const all_features = builtin.cpu.arch.allFeaturesList();
            for (all_features, 0..) |feature, index_usize| {
                const index: std.Target.Cpu.Feature.Set.Index = @intCast(index_usize);
                const is_in_model = builtin.cpu.model.features.isEnabled(index);
                const is_enabled = builtin.cpu.features.isEnabled(index);
                if (is_enabled and !is_in_model)
                    cpu_str = cpu_str ++ "+" ++ feature.name
                else if (!is_enabled and is_in_model)
                    cpu_str = cpu_str ++ "-" ++ feature.name;
            }
            break :cpu_str cpu_str;
        };
        try std.Io.File.stdout().writeStreamingAll(io, cpu_str);
    } else if (std.mem.eql(u8, args[0], "print-opt")) {
        try std.Io.File.stdout().writeStreamingAll(io, @tagName(builtin.mode));
    } else {
        std.debug.print("unknown command: {s}\n", .{args[0]});
        std.process.exit(1);
    }
}

pub fn alwaysWantNativeDirs() bool {
    return getEnvKind() == .autobuild and @atomicLoad(bool, &options.always_native_dirs, .acquire);
}
