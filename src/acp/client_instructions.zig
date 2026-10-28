//! Client-provided system prompt for ACP sessions in append or replace mode.
//! The prompt is validated before a
//! session exists, persisted with the session, restored on load and resume,
//! and delivered as an appended instruction or the root base policy.

const std = @import("std");
const acp_types = @import("types.zig");
const io_mod = @import("../core/shared/io.zig");
const session_child_store = @import("../core/session/session_child_store.zig");

const Allocator = std.mem.Allocator;

pub const max_bytes: usize = 64 * 1024;
pub const Mode = enum { append, replace };
pub const policy_file_name = "system-prompt.json";
const StoredPolicy = struct { mode: Mode, text: []const u8 };
/// The side file a v1 session keeps the prompt in.
pub const file_name = "system-prompt.txt";
const block_separator = "\n\n";

pub const ParseError = Allocator.Error || error{
    InvalidParams,
    InvalidSystemPrompt,
    EmptySystemPrompt,
    BlankSystemPrompt,
    UnsupportedSystemPromptBlock,
    SystemPromptTooLarge,
    InvalidSystemPromptText,
    DuplicateSystemPrompt,
    SystemPromptModeWithoutPrompt,
    UnsupportedSystemPromptMode,
};

/// Returns the owned prompt from `session/new` params, or null when absent.
/// `systemPrompt` is the RFD field. `_meta.fx.systemPrompt` carries the same
/// content for clients whose SDK drops unknown request fields.
pub fn parse(alloc: Allocator, params_raw: ?[]const u8) ParseError!?[]u8 {
    const raw = params_raw orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;
    const params = parsed.value.object;

    const standard = params.get("systemPrompt");
    const extension = acp_types.fxMetaField(params, "systemPrompt");
    if (standard != null and extension != null) return error.DuplicateSystemPrompt;
    const blocks = standard orelse extension;

    if (params.get("systemPromptMode")) |mode| {
        if (blocks == null) return error.SystemPromptModeWithoutPrompt;
        if (mode != .string or std.meta.stringToEnum(Mode, mode.string) == null) {
            return error.UnsupportedSystemPromptMode;
        }
    }
    return try joinTextBlocks(alloc, blocks orelse return null);
}

/// Reads the mode after `parse` has validated the request.
pub fn requestMode(alloc: Allocator, params_raw: ?[]const u8) !Mode {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, params_raw orelse return .append, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("systemPromptMode") orelse return .append;
    return std.meta.stringToEnum(Mode, value.string) orelse error.UnsupportedSystemPromptMode;
}

/// Missing mode means append for sessions created before replacement existed.
pub fn restoredMode(text: ?[]const u8) !Mode {
    return if (text) |value| std.meta.stringToEnum(Mode, value) orelse error.UnsupportedSystemPromptMode else .append;
}

pub fn persistPolicy(alloc: Allocator, capability: *session_child_store.SessionChildCapability, text: []const u8, mode: Mode) !void {
    if (mode == .append) return persist(alloc, capability, text);
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    try std.json.Stringify.value(StoredPolicy{ .mode = mode, .text = text }, .{}, &json.writer);
    var entry = try capability.atomicReplace(alloc, .client_context, policy_file_name, json.written());
    entry.deinit(alloc);
}

fn loadPolicy(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !?std.json.Parsed(StoredPolicy) {
    var file = capability.openFileReadOnly(alloc, .client_context, policy_file_name) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    const json = try file.readToEnd(alloc, max_bytes * 6 + 128);
    defer alloc.free(json);
    const policy = try std.json.parseFromSlice(StoredPolicy, alloc, json, .{ .allocate = .alloc_always });
    errdefer policy.deinit();
    if (policy.value.text.len == 0 or policy.value.text.len > max_bytes or !validText(policy.value.text)) return error.InvalidSystemPromptText;
    return policy;
}

pub fn loadMode(alloc: Allocator, capability: *session_child_store.SessionChildCapability) !Mode {
    const policy = (try loadPolicy(alloc, capability)) orelse return .append;
    defer policy.deinit();
    return policy.value.mode;
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory",
        error.InvalidParams => "Invalid params",
        error.InvalidSystemPrompt => "systemPrompt must be an array of content blocks",
        error.EmptySystemPrompt => "systemPrompt must contain at least one content block",
        error.BlankSystemPrompt => "systemPrompt text cannot be empty",
        error.UnsupportedSystemPromptBlock => "systemPrompt supports text content blocks only",
        error.SystemPromptTooLarge => "systemPrompt exceeds the 64 KiB limit",
        error.InvalidSystemPromptText => "systemPrompt text must be valid UTF-8 without NUL bytes",
        error.DuplicateSystemPrompt => "Send systemPrompt or _meta.fx.systemPrompt, not both",
        error.SystemPromptModeWithoutPrompt => "systemPromptMode requires systemPrompt",
        error.UnsupportedSystemPromptMode => "systemPromptMode supports \"append\" or \"replace\"",
    };
}

fn joinTextBlocks(alloc: Allocator, blocks: std.json.Value) ParseError![]u8 {
    if (blocks != .array) return error.InvalidSystemPrompt;
    if (blocks.array.items.len == 0) return error.EmptySystemPrompt;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    for (blocks.array.items, 0..) |block, index| {
        if (block != .object) return error.UnsupportedSystemPromptBlock;
        const kind = block.object.get("type") orelse return error.UnsupportedSystemPromptBlock;
        const value = block.object.get("text") orelse return error.UnsupportedSystemPromptBlock;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text") or value != .string) {
            return error.UnsupportedSystemPromptBlock;
        }
        // `text` never exceeds `max_bytes`, so the subtraction cannot wrap.
        const separator_len: usize = if (index == 0) 0 else block_separator.len;
        const added = value.string.len + separator_len;
        if (added > max_bytes - text.items.len) return error.SystemPromptTooLarge;
        if (index > 0) try text.appendSlice(alloc, block_separator);
        try text.appendSlice(alloc, value.string);
    }
    if (std.mem.trim(u8, text.items, " \t\r\n").len == 0) return error.BlankSystemPrompt;
    if (!validText(text.items)) return error.InvalidSystemPromptText;
    return text.toOwnedSlice(alloc);
}

fn validText(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.findScalar(u8, text, 0) == null;
}

/// Stores the prompt with its session so load and resume restore it.
pub fn persist(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    text: []const u8,
) !void {
    var entry = try capability.atomicReplace(alloc, .client_context, file_name, text);
    entry.deinit(alloc);
}

/// Returns the owned persisted prompt, or null when the session has none.
pub fn load(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !?[]u8 {
    if (try loadPolicy(alloc, capability)) |policy| {
        defer policy.deinit();
        return try alloc.dupe(u8, policy.value.text);
    }
    var file = capability.openFileReadOnly(alloc, .client_context, file_name) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    // The reader rejects a file that reaches its limit, so allow one byte
    // more to accept a prompt of exactly `max_bytes`.
    const text = try file.readToEnd(alloc, max_bytes + 1);
    errdefer alloc.free(text);
    if (text.len == 0 or !validText(text)) return error.InvalidSystemPromptText;
    return text;
}

/// Joins host instructions with the client prompt for the system slot, after
/// fx's built-in instructions. Caller owns the result.
pub fn compose(alloc: Allocator, host_instructions: []const u8, client_prompt: []const u8) ![]u8 {
    if (client_prompt.len == 0) return alloc.dupe(u8, host_instructions);
    const separator = if (host_instructions.len > 0) "\n\n" else "";
    return std.mem.concat(alloc, u8, &.{
        host_instructions,
        separator,
        "<client_instructions>\n",
        client_prompt,
        "\n</client_instructions>",
    });
}

test "client system prompt parses RFD text blocks in append mode" {
    const alloc = std.testing.allocator;
    const text = (try parse(alloc,
        \\{"cwd":"/tmp","systemPrompt":[{"type":"text","text":"You run inside Mini."},{"type":"text","text":"Use browser tools."}],"systemPromptMode":"append"}
    )).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("You run inside Mini.\n\nUse browser tools.", text);

    const meta = (try parse(alloc,
        \\{"_meta":{"fx":{"systemPrompt":[{"type":"text","text":"From meta."}]}}}
    )).?;
    defer alloc.free(meta);
    try std.testing.expectEqualStrings("From meta.", meta);

    try std.testing.expect((try parse(alloc, "{\"cwd\":\"/tmp\"}")) == null);
}

test "client system prompt rejects invalid combinations before a session exists" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: ParseError }{
        .{ .json = "{\"systemPrompt\":[]}", .expected = error.EmptySystemPrompt },
        .{ .json = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\" \"}]}", .expected = error.BlankSystemPrompt },
        .{ .json = "{\"systemPrompt\":\"text\"}", .expected = error.InvalidSystemPrompt },
        .{ .json = "{\"systemPrompt\":[{\"type\":\"image\",\"data\":\"x\"}]}", .expected = error.UnsupportedSystemPromptBlock },
        .{ .json = "{\"systemPromptMode\":\"append\"}", .expected = error.SystemPromptModeWithoutPrompt },
        .{ .json = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"x\"}],\"systemPromptMode\":\"override\"}", .expected = error.UnsupportedSystemPromptMode },
        .{ .json = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"a\"}],\"_meta\":{\"fx\":{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"b\"}]}}}", .expected = error.DuplicateSystemPrompt },
        .{ .json = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"a\\u0000b\"}]}", .expected = error.InvalidSystemPromptText },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, parse(alloc, case.json));
    }

    const oversized = try alloc.alloc(u8, max_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    const json = try alloc.print("{{\"systemPrompt\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}", .{oversized});
    defer alloc.free(json);
    try std.testing.expectError(error.SystemPromptTooLarge, parse(alloc, json));
}

test "client system prompt composes after host instructions" {
    const alloc = std.testing.allocator;
    const only_host = try compose(alloc, "host", "");
    defer alloc.free(only_host);
    try std.testing.expectEqualStrings("host", only_host);

    const both = try compose(alloc, "host", "client");
    defer alloc.free(both);
    try std.testing.expectEqualStrings("host\n\n<client_instructions>\nclient\n</client_instructions>", both);

    const only_client = try compose(alloc, "", "client");
    defer alloc.free(only_client);
    try std.testing.expectEqualStrings("<client_instructions>\nclient\n</client_instructions>", only_client);
}

test "client system prompt of exactly the size limit survives a restore" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Session directories must be private for the child store to open them.
    try tmp.dir.createDir(std.testing.io, "session", std.Io.File.Permissions.fromMode(0o700));
    var session_dir = try tmp.dir.openDir(std.testing.io, "session", .{ .iterate = true, .follow_symlinks = false });
    defer session_dir.close(std.testing.io);
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(alloc, session_dir, session_path, .writable, .{});
    defer capability.deinit();

    const text = try alloc.alloc(u8, max_bytes);
    defer alloc.free(text);
    @memset(text, 'a');
    try persist(alloc, &capability, text);
    const restored = (try load(alloc, &capability)).?;
    defer alloc.free(restored);
    try std.testing.expectEqual(max_bytes, restored.len);
}

test "ACP replacement mode and atomic policy restore reject invalid modes" {
    const alloc = std.testing.allocator;
    const request = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"host policy\"}],\"systemPromptMode\":\"replace\"}";
    const text = (try parse(alloc, request)).?;
    defer alloc.free(text);
    try std.testing.expectEqual(Mode.replace, try requestMode(alloc, request));
    try std.testing.expectEqual(Mode.append, try requestMode(alloc, "{}"));
    try std.testing.expectEqual(Mode.append, try restoredMode(null));
    try std.testing.expectError(error.UnsupportedSystemPromptMode, restoredMode("invalid"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "session", std.Io.File.Permissions.fromMode(0o700));
    var dir = try tmp.dir.openDir(std.testing.io, "session", .{ .iterate = true });
    defer dir.close(std.testing.io);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(alloc, dir, path, .writable, .{});
    defer capability.deinit();
    try persistPolicy(alloc, &capability, text, .replace);
    const restored = (try load(alloc, &capability)).?;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings(text, restored);
    try std.testing.expectEqual(Mode.replace, try loadMode(alloc, &capability));
    // Control bytes exercise the JSON envelope's maximum escaping expansion.
    const full = try alloc.alloc(u8, max_bytes);
    defer alloc.free(full);
    @memset(full, 1);
    try persistPolicy(alloc, &capability, full, .replace);
    const full_restored = (try load(alloc, &capability)).?;
    defer alloc.free(full_restored);
    try std.testing.expectEqualSlices(u8, full, full_restored);
    var corrupted = try capability.atomicReplace(alloc, .client_context, policy_file_name, "{\"mode\":\"unknown\",\"text\":\"host\"}");
    corrupted.deinit(alloc);
    try std.testing.expectError(error.InvalidEnumTag, load(alloc, &capability));
}
