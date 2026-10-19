//! Opt-in host observations over effective model inputs and tool projections.
//! Content is a bounded visible-text projection, never credentials, provider
//! replay, hidden reasoning, HTTP headers, or transport configuration.
const std = @import("std");
const types = @import("../shared/types.zig");
const trace = @import("../shared/debug_trace.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    enabled: bool = false,
    capture_content: bool = false,
    max_content_bytes: usize = 262144,

    pub fn parse(value: ?std.json.Value) !Options {
        const root = value orelse return .{};
        if (root != .object) return error.InvalidObservationOptions;
        for (root.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "version") and !std.mem.eql(u8, key, "capture_content") and !std.mem.eql(u8, key, "max_content_bytes")) return error.InvalidObservationOptions;
        }
        const version = root.object.get("version") orelse return error.InvalidObservationOptions;
        if (version != .integer or version.integer != 1) return error.InvalidObservationOptions;
        var result = Options{ .enabled = true };
        if (root.object.get("capture_content")) |item| {
            if (item != .bool) return error.InvalidObservationOptions;
            result.capture_content = item.bool;
        }
        if (root.object.get("max_content_bytes")) |item| {
            if (item != .integer or item.integer < 1 or item.integer > 1048576) return error.InvalidObservationOptions;
            result.max_content_bytes = @intCast(item.integer);
        }
        return result;
    }
};

pub const RequestBody = struct {
    sha256: ?[]const u8,
    byte_count: ?usize,
    content_json: ?[]const u8,
    content_sha256: []const u8,
    omitted: bool,
    content_projection: []const u8 = "visible_text_no_reasoning",
};
pub const ModelRequest = struct {
    model: []const u8,
    available_tool_names: []const []const u8,
    request: RequestBody,
    tool_call_ids: []const []const u8,
};
pub const ModelFinished = struct {
    model: []const u8,
    tool_call_ids: []const []const u8 = &.{},
    outcome: enum { completed, failed, cancelled },
    delivery: enum { definitely_unsent, possibly_sent },
    admitted: bool,
    output_text: ?[]const u8,
    output_omitted: bool,
    output_sha256: ?[]const u8,
    output_byte_count: ?usize,
    usage: ?struct { input_tokens: ?u64, output_tokens: ?u64 } = null,
    error_type: ?[]const u8 = null,
};
pub const Digest = struct { sha256: []const u8, byte_count: usize };
pub const ToolPrepared = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    original: Digest,
    model_visible: struct { sha256: []const u8, byte_count: usize, content_text: ?[]const u8, omitted: bool },
    truncated: bool,
    stored_handle: ?[]const u8,
};
pub const Event = union(enum) {
    model_request: ModelRequest,
    model_finished: ModelFinished,
    tool_prepared: ToolPrepared,
};
pub const RequestDetails = struct {
    available_tool_names: []const []const u8 = &.{},
    tool_choice: types.ToolChoice = .auto,
    max_output_tokens: ?u32 = null,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
};
pub const Context = struct { trace: trace.TraceContext, attempt: ?u32 = null };
pub const Sink = struct {
    context: ?*anyopaque = null,
    emit_fn: ?*const fn (*anyopaque, Context, Event) void = null,
    options: Options = .{},

    pub fn enabled(self: Sink) bool {
        return self.options.enabled and self.emit_fn != null and self.context != null;
    }
    pub fn emit(self: Sink, context: Context, event: Event) void {
        if (self.enabled()) self.emit_fn.?(self.context.?, context, event);
    }
    pub fn request(self: Sink, alloc: Allocator, context: Context, model: []const u8, body: ?[]const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, details: RequestDetails) void {
        if (!self.enabled()) return;
        self.captureRequest(alloc, context, model, body, instructions, messages, details) catch {};
    }
    fn captureRequest(self: Sink, alloc: Allocator, context: Context, model: []const u8, body: ?[]const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, details: RequestDetails) !void {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var out = std.Io.Writer.Allocating.init(arena);
        defer out.deinit();
        try out.writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model, .{}, &out.writer);
        try out.writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(details, .{}, &out.writer);
        try out.writer.writeAll(",\"tools\":");
        if (body) |wire| {
            const parsed = std.json.parseFromSlice(std.json.Value, arena, wire, .{}) catch null;
            if (parsed) |value| {
                defer value.deinit();
                const tools = if (value.value == .object) value.value.object.get("tools") else null;
                if (tools) |definitions| try std.json.Stringify.value(definitions, .{}, &out.writer) else try out.writer.writeAll("null");
            } else try out.writer.writeAll("null");
        } else try out.writer.writeAll("null");
        try out.writer.writeAll(",\"instructions\":");
        try writeMessages(arena, &out.writer, instructions);
        try out.writer.writeAll(",\"messages\":");
        try writeMessages(arena, &out.writer, messages);
        try out.writer.writeByte('}');
        const content = out.writer.buffered();
        var ids: std.ArrayList([]const u8) = .empty;
        for (messages) |message| {
            if (message.tool_call_id) |id| try ids.append(arena, id);
        }
        const omitted = !self.options.capture_content or content.len > self.options.max_content_bytes;
        self.emit(context, .{ .model_request = .{
            .model = model,
            .available_tool_names = details.available_tool_names,
            .request = .{ .sha256 = if (body) |value| try digest(arena, value) else null, .byte_count = if (body) |value| value.len else null, .content_json = if (omitted) null else content, .content_sha256 = try digest(arena, content), .omitted = omitted },
            .tool_call_ids = ids.items,
        } });
    }
    pub fn tool(self: Sink, alloc: Allocator, context: Context, id: []const u8, name: []const u8, original: []const u8, visible: []const u8, truncated: bool, handle: ?[]const u8) void {
        if (!self.enabled()) return;
        self.captureTool(alloc, context, id, name, original, visible, truncated, handle) catch {};
    }
    fn captureTool(self: Sink, alloc: Allocator, context: Context, id: []const u8, name: []const u8, original: []const u8, visible: []const u8, truncated: bool, handle: ?[]const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const omitted = !self.options.capture_content or visible.len > self.options.max_content_bytes;
        self.emit(context, .{ .tool_prepared = .{ .tool_call_id = id, .tool_name = name, .original = .{ .sha256 = try digest(arena, original), .byte_count = original.len }, .model_visible = .{ .sha256 = try digest(arena, visible), .byte_count = visible.len, .content_text = if (omitted) null else visible, .omitted = omitted }, .truncated = truncated, .stored_handle = handle } });
    }
    pub fn finished(self: Sink, alloc: Allocator, context: Context, value: ModelFinished) void {
        if (!self.enabled()) return;
        var event = value;
        var hash: [64]u8 = undefined;
        if (value.output_text) |text| {
            hash = hashText(text);
            event.output_sha256 = &hash;
            event.output_byte_count = text.len;
            event.output_omitted = !self.options.capture_content or text.len > self.options.max_content_bytes;
            if (event.output_omitted) event.output_text = null;
        }
        _ = alloc;
        self.emit(context, .{ .model_finished = event });
    }
};

fn hashText(text: []const u8) [64]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &bytes, .{});
    return std.fmt.bytesToHex(bytes, .lower);
}
fn digest(alloc: Allocator, text: []const u8) ![]const u8 {
    return alloc.dupe(u8, &hashText(text));
}
fn writeMessages(alloc: Allocator, writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    try writer.writeByte('[');
    for (messages, 0..) |message, index| {
        if (index != 0) try writer.writeByte(',');
        const Call = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
        const calls = try alloc.alloc(Call, message.tool_calls.len);
        for (message.tool_calls, calls) |call, *copy| copy.* = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json };
        try std.json.Stringify.value(.{ .role = @tagName(message.role), .content = message.content, .tool_call_id = message.tool_call_id, .tool_name = message.tool_name, .tool_calls = calls }, .{}, writer);
    }
    try writer.writeByte(']');
}

test "observations options require explicit supported bounded opt in" {
    try std.testing.expect(!(try Options.parse(null)).enabled);
    const value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"version\":1,\"capture_content\":true,\"max_content_bytes\":262144}", .{});
    defer value.deinit();
    const parsed = try Options.parse(value.value);
    try std.testing.expect(parsed.enabled and parsed.capture_content);
    const invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"version\":1,\"max_content_bytes\":1048577}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidObservationOptions, Options.parse(invalid.value));
}

const TestCollector = struct {
    data: ?[]u8 = null,
    count: usize = 0,
    fn emit(raw: *anyopaque, _: Context, event: Event) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.count += 1;
        if (self.data) |data| std.testing.allocator.free(data);
        self.data = std.json.Stringify.valueAlloc(std.testing.allocator, event, .{}) catch unreachable;
    }
    fn deinit(self: *@This()) void {
        if (self.data) |data| std.testing.allocator.free(data);
    }
};

test "observations capture effective text without wire bodies or hidden replay" {
    var collector = TestCollector{};
    defer collector.deinit();
    const sink = Sink{ .context = &collector, .emit_fn = TestCollector.emit, .options = .{ .enabled = true, .capture_content = true } };
    const messages = [_]types.ChatMessage{.{ .role = .tool, .content = "VISIBLE_MANAGED_RECEIPT", .tool_call_id = "call_1", .provider_replay = .{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "PRIVATE_REASONING_REPLAY" } }};
    sink.request(std.testing.allocator, .{ .trace = .{}, .attempt = 2 }, "test", "PRIVATE_WIRE_REASONING", &.{}, &messages, .{});
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expect(std.mem.find(u8, collector.data.?, "VISIBLE_MANAGED_RECEIPT") != null);
    try std.testing.expect(std.mem.find(u8, collector.data.?, "PRIVATE_") == null);
    try std.testing.expect(std.mem.find(u8, collector.data.?, "visible_text_no_reasoning") != null);
    try std.testing.expect(std.mem.find(u8, collector.data.?, &hashText("PRIVATE_WIRE_REASONING")) != null);
}

test "observations omit bounded content explicitly and stay silent by default" {
    var collector = TestCollector{};
    defer collector.deinit();
    var sink = Sink{ .context = &collector, .emit_fn = TestCollector.emit };
    sink.tool(std.testing.allocator, .{ .trace = .{} }, "call_1", "mcp_test", "original", "VISIBLE_RECEIPT", true, "handle");
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    sink.options = .{ .enabled = true, .capture_content = true, .max_content_bytes = 1 };
    sink.tool(std.testing.allocator, .{ .trace = .{} }, "call_1", "mcp_test", "original", "VISIBLE_RECEIPT", true, "handle");
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expect(std.mem.find(u8, collector.data.?, "VISIBLE_RECEIPT") == null);
    try std.testing.expect(std.mem.find(u8, collector.data.?, "\"omitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, collector.data.?, &hashText("VISIBLE_RECEIPT")) != null);
}
