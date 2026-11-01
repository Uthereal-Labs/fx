const std = @import("std");
const io_mod = @import("../shared/io.zig");
const child_store = @import("session_child_store.zig");

const Allocator = std.mem.Allocator;
const record_prefix = "tool-result-aliases-";
const max_entries = 4096;
const max_bytes = 1024 * 1024;
// Duplicated capabilities share an owner without sharing their wrapper.
var mutex: std.Io.Mutex = .init;

const Registry = struct {
    version: u8 = 1,
    owner: []const u8,
    handles: []const []const u8 = &.{},
};

pub fn isAlias(handle: []const u8) bool {
    return std.mem.startsWith(u8, handle, "F");
}

pub fn register(alloc: Allocator, capability: *child_store.SessionChildCapability, physical: []const u8) ![]u8 {
    try validatePhysical(physical);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var lock: ?io_mod.TimedAdvisoryLock = null;
    defer if (lock) |*held| held.release();
    if (!capability.holdsBlobs()) lock = try capability.acquireTimedAdvisoryLock(.tool_results, "tool-result-aliases.lock", 1000);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = try load(a, capability);
    const record_name = try recordName(a, registry.owner);
    for (registry.handles, 0..) |known, index| {
        if (std.mem.eql(u8, known, physical)) return format(alloc, registry.owner, index);
    }
    if (registry.handles.len == max_entries) return error.ResultAliasLimit;
    const handles = try a.alloc([]const u8, registry.handles.len + 1);
    @memcpy(handles[0..registry.handles.len], registry.handles);
    handles[registry.handles.len] = physical;
    registry.handles = handles;
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(registry, .{}, &out.writer);
    if (out.written().len > max_bytes) return error.ResultAliasLimit;
    if (capability.holdsBlobs()) {
        try capability.putRecord(record_name, out.written());
    } else {
        var entry = try capability.atomicReplace(a, .tool_results, record_name, out.written());
        entry.deinit(a);
    }
    return format(alloc, registry.owner, handles.len - 1);
}

pub fn display(alloc: Allocator, capability: *child_store.SessionChildCapability, physical: []const u8) ![]u8 {
    validateOwner(capability.ownerID()) catch |err| {
        // Legacy creation replays history from an unpublished `creating+...`
        // directory. It has no alias owner yet. Keep physical previews only
        // when there is no registry to bypass or silently reinterpret.
        if (capability.holdsBlobs()) return err;
        var entries = try capability.iterate(alloc, .tool_results);
        defer entries.deinit();
        for (entries.names) |name| if (std.mem.startsWith(u8, name, record_prefix)) return err;
        return alloc.dupe(u8, physical);
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const registry = try load(arena.allocator(), capability);
    for (registry.handles, 0..) |known, index| {
        if (std.mem.eql(u8, known, physical)) return format(alloc, registry.owner, index);
    }
    return alloc.dupe(u8, physical);
}

pub fn resolve(alloc: Allocator, capability: *child_store.SessionChildCapability, alias: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const registry = try load(a, capability);
    for (registry.handles, 0..) |physical, index| {
        const expected = try format(a, registry.owner, index);
        if (std.mem.eql(u8, expected, alias)) return alloc.dupe(u8, physical);
    }
    return error.UnknownResultAlias;
}

fn format(alloc: Allocator, owner: []const u8, index: usize) ![]u8 {
    return alloc.print("F{s}:{d}", .{ owner, index + 1 });
}

fn recordName(alloc: Allocator, owner: []const u8) ![]u8 {
    return alloc.print(record_prefix ++ "{s}.json", .{owner});
}

fn validatePhysical(physical: []const u8) !void {
    if (physical.len > 256 or !std.mem.startsWith(u8, physical, "result-") or !std.mem.endsWith(u8, physical, ".txt")) return error.InvalidResultAlias;
    for (physical) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidResultAlias;
}

fn validateOwner(owner: []const u8) !void {
    if (owner.len == 0 or owner.len > 128) return error.InvalidResultAliasOwner;
    for (owner) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidResultAliasOwner;
}

fn load(alloc: Allocator, capability: *child_store.SessionChildCapability) !Registry {
    const owner = capability.ownerID();
    try validateOwner(owner);
    const record_name = try recordName(alloc, owner);
    const bytes = if (capability.holdsBlobs())
        capability.readBlob(alloc, .tool_results, record_name, max_bytes) catch |err| switch (err) {
            error.BlobNotFound => return .{ .owner = owner },
            else => return err,
        }
    else blk: {
        var file = capability.openFileReadOnly(alloc, .tool_results, record_name) catch |err| switch (err) {
            error.FileNotFound => return .{ .owner = owner },
            else => return err,
        };
        defer file.deinit();
        const size = (try file.stat()).size;
        if (size > max_bytes) return error.ResultAliasLimit;
        break :blk try file.readRange(alloc, 0, @intCast(size));
    };
    const registry = try std.json.parseFromSliceLeaky(Registry, alloc, bytes, .{});
    if (registry.version != 1 or !std.mem.eql(u8, registry.owner, owner)) return error.InvalidResultAliasOwner;
    if (registry.handles.len > max_entries) return error.ResultAliasLimit;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (registry.handles) |physical| {
        try validatePhysical(physical);
        const entry = try seen.getOrPut(alloc, physical);
        if (entry.found_existing) return error.InvalidResultAlias;
    }
    return registry;
}

test "short result aliases persist exact native owners and reject foreign children" {
    const alloc = std.testing.allocator;
    var root = child_store.MemoryBlobsForTesting.init(alloc);
    defer root.deinit();
    root.owner_id = "root-session";
    var child = child_store.MemoryBlobsForTesting.init(alloc);
    defer child.deinit();
    child.owner_id = "child-session";
    var root_cap = try child_store.SessionChildCapability.initBlobs(alloc, root.blobs(), "", .writable);
    defer root_cap.deinit();
    var child_cap = try child_store.SessionChildCapability.initBlobs(alloc, child.blobs(), "", .writable);
    defer child_cap.deinit();
    const first = try register(alloc, &root_cap, "result-physical-one.txt");
    defer alloc.free(first);
    try std.testing.expectEqualStrings("Froot-session:1", first);
    const duplicate = try register(alloc, &root_cap, "result-physical-one.txt");
    defer alloc.free(duplicate);
    try std.testing.expectEqualStrings(first, duplicate);
    const other = try register(alloc, &child_cap, "result-physical-two.txt");
    defer alloc.free(other);
    try std.testing.expectEqualStrings("Fchild-session:1", other);
    try std.testing.expectError(error.UnknownResultAlias, resolve(alloc, &root_cap, other));
    try std.testing.expectError(error.UnknownResultAlias, resolve(alloc, &child_cap, first));
    try std.testing.expectError(error.UnknownResultAlias, resolve(alloc, &root_cap, "Froot-session:01"));
    try std.testing.expectError(error.UnknownResultAlias, resolve(alloc, &root_cap, "Froot-session:2"));
    var resumed = try root_cap.duplicate(alloc);
    defer resumed.deinit();
    const physical = try resolve(alloc, &resumed, first);
    defer alloc.free(physical);
    try std.testing.expectEqualStrings("result-physical-one.txt", physical);
    const shown = try display(alloc, &resumed, physical);
    defer alloc.free(shown);
    try std.testing.expectEqualStrings(first, shown);
    const historical = try display(alloc, &resumed, "result-historical.txt");
    defer alloc.free(historical);
    try std.testing.expectEqualStrings("result-historical.txt", historical);
}

test "short result aliases serialize concurrent duplicate admission" {
    const alloc = std.testing.allocator;
    var memory = child_store.MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    var capability = try child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();
    const Worker = struct {
        capability: *child_store.SessionChildCapability,
        failed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            for (0..8) |_| {
                const alias = register(std.heap.page_allocator, self.capability, "result-shared.txt") catch {
                    self.failed.store(true, .release);
                    return;
                };
                defer std.heap.page_allocator.free(alias);
                if (!std.mem.eql(u8, alias, "Ftest-owner:1")) self.failed.store(true, .release);
            }
        }
    };
    var worker: Worker = .{ .capability = &capability };
    const one = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    const two = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |err| {
        one.join();
        return err;
    };
    one.join();
    two.join();
    try std.testing.expect(!worker.failed.load(.acquire));
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try load(arena.allocator(), &capability)).handles.len);
}

test "short result aliases inherited by a fork never become the new owner's aliases" {
    const alloc = std.testing.allocator;
    var memory = child_store.MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    memory.owner_id = "parent-owner";
    var capability = try child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();
    const original = try register(alloc, &capability, "result-parent.txt");
    defer alloc.free(original);
    memory.owner_id = "fork-owner";
    try std.testing.expectError(error.UnknownResultAlias, resolve(alloc, &capability, original));
    const next = try register(alloc, &capability, "result-parent.txt");
    defer alloc.free(next);
    try std.testing.expectEqualStrings("Ffork-owner:1", next);
}

test "short result aliases survive reopening a legacy owner and reject changed ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700));
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(path);
    var capability = try child_store.SessionChildCapability.init(alloc, tmp.dir, path, .writable);
    const alias = try register(alloc, &capability, "result-legacy.txt");
    defer alloc.free(alias);
    capability.deinit();
    var reopened = try child_store.SessionChildCapability.init(alloc, tmp.dir, path, .read_only);
    defer reopened.deinit();
    const physical = try resolve(alloc, &reopened, alias);
    defer alloc.free(physical);
    try std.testing.expectEqualStrings("result-legacy.txt", physical);
    const corrupt_path = try alloc.print("tool-results/" ++ record_prefix ++ "{s}.json", .{reopened.ownerID()});
    defer alloc.free(corrupt_path);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = corrupt_path, .data = "{\"version\":1,\"owner\":\"foreign\",\"handles\":[\"result-legacy.txt\"]}" });
    try std.testing.expectError(error.InvalidResultAliasOwner, resolve(alloc, &reopened, alias));
    try std.testing.expectError(error.InvalidResultAliasOwner, display(alloc, &reopened, "result-legacy.txt"));
}

test "short result display preserves unregistered legacy staging previews only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "creating+temporary", std.Io.File.Permissions.fromMode(0o700));
    var staging = try tmp.dir.openDir(io_mod.getIo(), "creating+temporary", .{ .iterate = true });
    defer staging.close(io_mod.getIo());
    const path = try io_mod.dirRealpathAlloc(alloc, staging, ".");
    defer alloc.free(path);
    var capability = try child_store.SessionChildCapability.init(alloc, staging, path, .writable);
    defer capability.deinit();
    const shown = try display(alloc, &capability, "saved-command-output.txt");
    defer alloc.free(shown);
    try std.testing.expectEqualStrings("saved-command-output.txt", shown);
    try std.testing.expectError(error.InvalidResultAliasOwner, register(alloc, &capability, "result-one.txt"));
    try std.testing.expectError(error.InvalidResultAliasOwner, resolve(alloc, &capability, "Ftemporary:1"));
    var entry = try capability.atomicReplace(alloc, .tool_results, "tool-result-aliases-native-owner.json", "{}");
    entry.deinit(alloc);
    try std.testing.expectError(error.InvalidResultAliasOwner, display(alloc, &capability, "saved-command-output.txt"));
}

test "short result aliases report exhaustion without changing existing bindings" {
    const alloc = std.testing.allocator;
    var memory = child_store.MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    var capability = try child_store.SessionChildCapability.initBlobs(alloc, memory.blobs(), "", .writable);
    defer capability.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const handles = try a.alloc([]const u8, max_entries);
    for (handles, 0..) |*handle, index| handle.* = try a.print("result-{d}.txt", .{index});
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(Registry{ .owner = capability.ownerID(), .handles = handles }, .{}, &out.writer);
    try capability.putRecord(try recordName(a, capability.ownerID()), out.written());
    try std.testing.expectError(error.ResultAliasLimit, register(alloc, &capability, "result-new.txt"));
    const existing = try resolve(alloc, &capability, "Ftest-owner:4096");
    defer alloc.free(existing);
    try std.testing.expectEqualStrings("result-4095.txt", existing);
    try std.testing.expectError(error.InvalidResultAlias, register(alloc, &capability, "../../foreign"));
}
