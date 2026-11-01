//! Opt-in host observations over effective model inputs and tool projections.
//! Content is a bounded visible-text projection, never credentials, provider
//! replay, hidden reasoning, HTTP headers, or transport configuration.
const std = @import("std");
const types = @import("../shared/types.zig");
pub const TraceContext = @import("../shared/trace_context.zig").TraceContext;
const trace = @import("../shared/debug_trace.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    enabled: bool = false,
    version: u8 = 1,
    parent: ?TraceContext = null,
    capture_content: bool = false,
    max_content_bytes: usize = 262144,

    pub fn parse(value: ?std.json.Value) !Options {
        const root = value orelse return .{};
        if (root != .object) return error.InvalidObservationOptions;
        for (root.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "version") and !std.mem.eql(u8, key, "capture_content") and !std.mem.eql(u8, key, "max_content_bytes") and !std.mem.eql(u8, key, "traceparent") and !std.mem.eql(u8, key, "tracestate")) return error.InvalidObservationOptions;
        }
        const version = root.object.get("version") orelse return error.InvalidObservationOptions;
        if (version != .integer or version.integer < 1 or version.integer > 5) return error.InvalidObservationOptions;
        var result = Options{ .enabled = true, .version = @intCast(version.integer) };
        if (result.version >= 2 and (result.version < 5 or root.object.get("traceparent") != null)) {
            const parent = root.object.get("traceparent") orelse return error.InvalidObservationOptions;
            const state = root.object.get("tracestate");
            if (parent != .string or state != null and state.? != .string) return error.InvalidObservationOptions;
            result.parent = try TraceContext.parse(parent.string, if (state) |s| s.string else null);
        }
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
    usage: ?types.Usage = null,
    error_type: ?[]const u8 = null,
    response: ?AssistantResponse = null,
};
pub const AssistantResponse = struct {
    content_json: ?[]const u8,
    sha256: []const u8,
    byte_count: usize,
    omitted: bool,
    content_projection: enum { assistant_message_no_reasoning } = .assistant_message_no_reasoning,
};
const ProjectedToolCall = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const Digest = struct { sha256: []const u8, byte_count: usize };
pub const ToolPrepared = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    original: Digest,
    model_visible: struct { sha256: []const u8, byte_count: usize, content_text: ?[]const u8, omitted: bool },
    truncated: bool,
    stored_handle: ?[]const u8,
};
pub const ToolStarted = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    arguments_json: ?[]const u8,
    arguments_sha256: []const u8,
    arguments_byte_count: usize,
    arguments_omitted: bool,
};
pub const ToolFinished = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    outcome: enum { completed, failed, cancelled },
    output_text: ?[]const u8,
    output_sha256: ?[]const u8,
    output_byte_count: ?usize,
    output_omitted: bool,
    error_type: ?[]const u8,
};
pub const ChildStarted = struct {
    root_session_id: []const u8,
    parent_session_id: []const u8,
    tool_call_id: []const u8,
};
pub const ChildFinished = struct {
    outcome: enum { completed, failed, cancelled },
    error_type: ?[]const u8,
};
pub const Event = union(enum) {
    child_started: ChildStarted,
    child_finished: ChildFinished,
    tool_started: ToolStarted,
    tool_finished: ToolFinished,
    model_request: ModelRequest,
    model_finished: ModelFinished,
    tool_prepared: ToolPrepared,
};

/// Preserve older negotiated payloads when a newer event adds fields.
pub fn writeEventData(writer: *std.Io.Writer, event: Event, version: u8) !void {
    switch (event) {
        .model_finished => |value| {
            if (version >= 5) return std.json.Stringify.value(value, .{}, writer);
            const usage = if (value.usage) |u| .{ .input_tokens = u.input_tokens, .output_tokens = u.output_tokens } else null;
            if (version == 4) return std.json.Stringify.value(.{
                .model = value.model,
                .tool_call_ids = value.tool_call_ids,
                .outcome = value.outcome,
                .delivery = value.delivery,
                .admitted = value.admitted,
                .output_text = value.output_text,
                .output_omitted = value.output_omitted,
                .output_sha256 = value.output_sha256,
                .output_byte_count = value.output_byte_count,
                .usage = usage,
                .error_type = value.error_type,
                .response = value.response,
            }, .{}, writer);
            try std.json.Stringify.value(.{
                .model = value.model,
                .tool_call_ids = value.tool_call_ids,
                .outcome = value.outcome,
                .delivery = value.delivery,
                .admitted = value.admitted,
                .output_text = value.output_text,
                .output_omitted = value.output_omitted,
                .output_sha256 = value.output_sha256,
                .output_byte_count = value.output_byte_count,
                .usage = usage,
                .error_type = value.error_type,
            }, .{}, writer);
        },
        inline else => |value| try std.json.Stringify.value(value, .{}, writer),
    }
}
pub const RequestDetails = struct {
    available_tool_names: []const []const u8 = &.{},
    tool_choice: types.ToolChoice = .auto,
    max_output_tokens: ?u32 = null,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
};
pub const Context = struct {
    trace: trace.TraceContext,
    request_id: ?[]const u8 = null,
    attempt: ?u32 = null,
    span: ?TraceContext = null,
    session_id: ?[]const u8 = null,
    work_id: ?[]const u8 = null,
};
pub const Sink = struct {
    context: ?*anyopaque = null,
    emit_fn: ?*const fn (*anyopaque, Context, Event) void = null,
    options: Options = .{},
    session_id: ?[]const u8 = null,
    work_id: ?[]const u8 = null,

    pub fn enabled(self: Sink) bool {
        return self.options.enabled and self.emit_fn != null and self.context != null;
    }
    pub fn emit(self: Sink, context: Context, event: Event) void {
        if (!self.enabled()) return;
        var identified = context;
        identified.session_id = context.session_id orelse self.session_id;
        identified.work_id = context.work_id orelse self.work_id;
        self.emit_fn.?(self.context.?, identified, event);
    }
    /// The caller owns the child and work IDs until finishChild returns.
    pub fn beginChild(self: Sink, child_id: []const u8, work_id: []const u8, call_id: []const u8) Sink {
        if (!self.enabled() or self.options.version < 3) return .{};
        const parent = self.options.parent;
        if (parent == null and self.options.version < 5) return .{};
        const root_id = self.session_id orelse return .{};
        var child = self;
        child.session_id = child_id;
        child.work_id = work_id;
        child.options.parent = if (parent) |value| value.child() else null;
        child.emit(.{ .trace = .{}, .span = child.options.parent }, .{ .child_started = .{
            .root_session_id = root_id,
            .parent_session_id = root_id,
            .tool_call_id = call_id,
        } });
        return child;
    }

    pub fn finishChild(self: Sink, outcome: ChildFinished) void {
        if (self.options.version < 3 or self.work_id == null) return;
        self.emit(.{ .trace = .{}, .span = self.options.parent }, .{ .child_finished = outcome });
    }

    pub fn beginTool(self: Sink, context: Context, call: types.ToolCall) Context {
        var current = context;
        if (!self.enabled() or self.options.version < 2) return current;
        current.span = if (context.span) |parent| parent.child() else if (self.options.parent) |parent| parent.child() else null;
        if (current.span == null and self.options.version < 5) return current;
        const omitted = !self.options.capture_content or call.arguments_json.len > self.options.max_content_bytes;
        var hash = hashText(call.arguments_json);
        self.emit(current, .{ .tool_started = .{
            .tool_call_id = call.id,
            .tool_name = call.name,
            .arguments_json = if (omitted) null else call.arguments_json,
            .arguments_sha256 = &hash,
            .arguments_byte_count = call.arguments_json.len,
            .arguments_omitted = omitted,
        } });
        return current;
    }

    pub fn finishTool(self: Sink, context: Context, call: types.ToolCall, output: ?[]const u8, failed: bool, cancelled: bool, error_type: ?[]const u8) void {
        if ((context.span == null and self.options.version < 5) or self.options.version < 2) return;
        var hash: [64]u8 = undefined;
        if (output) |text| hash = hashText(text);
        const omitted = !self.options.capture_content or output == null or output.?.len > self.options.max_content_bytes;
        self.emit(context, .{ .tool_finished = .{
            .tool_call_id = call.id,
            .tool_name = call.name,
            .outcome = if (cancelled) .cancelled else if (failed) .failed else .completed,
            .output_text = if (omitted) null else output,
            .output_sha256 = if (output != null) &hash else null,
            .output_byte_count = if (output) |text| text.len else null,
            .output_omitted = omitted,
            .error_type = error_type,
        } });
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
    pub fn finished(self: Sink, alloc: Allocator, context: Context, value: ModelFinished, calls: []const types.ToolCall) void {
        if (!self.enabled()) return;
        self.captureFinished(alloc, context, value, calls) catch {};
    }
    fn captureFinished(self: Sink, alloc: Allocator, context: Context, value: ModelFinished, calls: []const types.ToolCall) !void {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var event = value;
        var hash: [64]u8 = undefined;
        if (value.output_text) |text| {
            hash = hashText(text);
            event.output_sha256 = &hash;
            event.output_byte_count = text.len;
            event.output_omitted = !self.options.capture_content or text.len > self.options.max_content_bytes;
            if (event.output_omitted) event.output_text = null;
        }
        var response_hash: [64]u8 = undefined;
        if (self.options.version >= 4 and value.outcome == .completed) {
            const response = try std.json.Stringify.valueAlloc(arena, .{
                .role = @as(enum { assistant }, .assistant),
                .content = value.output_text,
                .tool_calls = try projectToolCalls(arena, calls),
            }, .{});
            response_hash = hashText(response);
            const omitted = !self.options.capture_content or response.len > self.options.max_content_bytes;
            event.response = .{ .content_json = if (omitted) null else response, .sha256 = &response_hash, .byte_count = response.len, .omitted = omitted };
        }
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
        const calls = try projectToolCalls(alloc, message.tool_calls);
        try std.json.Stringify.value(.{ .role = @tagName(message.role), .content = message.content, .tool_call_id = message.tool_call_id, .tool_name = message.tool_name, .tool_calls = calls }, .{}, writer);
    }
    try writer.writeByte(']');
}

fn projectToolCalls(alloc: Allocator, calls: []const types.ToolCall) ![]const ProjectedToolCall {
    const projected = try alloc.alloc(ProjectedToolCall, calls.len);
    for (calls, projected) |call, *copy| copy.* = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json };
    return projected;
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

test "observations v4 capture exact current tool calls without provider state" {
    var collector = TestCollector{};
    defer collector.deinit();
    const sink = Sink{ .context = &collector, .emit_fn = TestCollector.emit, .options = .{ .enabled = true, .version = 4, .capture_content = true } };
    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "capability_search", .arguments_json = "{\"query\":\"visible\"}", .provider_result = "PRIVATE_TOOL_RESULT" },
        .{ .id = "call_2", .name = "echo", .arguments_json = "malformed arguments stay unchanged" },
    };
    sink.finished(std.testing.allocator, .{ .trace = .{} }, .{ .model = "test", .outcome = .completed, .delivery = .possibly_sent, .admitted = true, .output_text = "Current response", .output_omitted = true, .output_sha256 = null, .output_byte_count = null }, &calls);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, collector.data.?, .{});
    defer parsed.deinit();
    const finished = parsed.value.object.get("model_finished").?.object;
    try std.testing.expectEqualStrings("Current response", finished.get("output_text").?.string);
    try std.testing.expectEqualStrings(&hashText("Current response"), finished.get("output_sha256").?.string);
    const response = finished.get("response").?.object;
    const content = response.get("content_json").?.string;
    try std.testing.expectEqualStrings(&hashText(content), response.get("sha256").?.string);
    try std.testing.expectEqual(content.len, @as(usize, @intCast(response.get("byte_count").?.integer)));
    const message = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer message.deinit();
    try std.testing.expectEqualStrings("assistant", message.value.object.get("role").?.string);
    try std.testing.expectEqualStrings("Current response", message.value.object.get("content").?.string);
    const projected = message.value.object.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    for (calls, projected) |call, value| {
        try std.testing.expectEqualStrings(call.id, value.object.get("id").?.string);
        try std.testing.expectEqualStrings(call.name, value.object.get("name").?.string);
        try std.testing.expectEqualStrings(call.arguments_json, value.object.get("arguments_json").?.string);
        try std.testing.expectEqual(@as(usize, 3), value.object.count());
    }
    try std.testing.expect(std.mem.find(u8, collector.data.?, "PRIVATE_") == null);
}

test "observations v4 response limits cover the whole tool-only message" {
    const expected = "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"name\":\"echo\",\"arguments_json\":\"{}\"}]}";
    for ([_]bool{ false, true }) |capture| {
        for ([_]usize{ 1, expected.len }) |limit| {
            var collector = TestCollector{};
            defer collector.deinit();
            const sink = Sink{ .context = &collector, .emit_fn = TestCollector.emit, .options = .{ .enabled = true, .version = 4, .capture_content = capture, .max_content_bytes = limit } };
            sink.finished(std.testing.allocator, .{ .trace = .{} }, .{ .model = "test", .outcome = .completed, .delivery = .possibly_sent, .admitted = true, .output_text = null, .output_omitted = true, .output_sha256 = null, .output_byte_count = null }, &.{.{ .id = "call_1", .name = "echo", .arguments_json = "{}" }});
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, collector.data.?, .{});
            defer parsed.deinit();
            const response = parsed.value.object.get("model_finished").?.object.get("response").?.object;
            try std.testing.expectEqualStrings(&hashText(expected), response.get("sha256").?.string);
            try std.testing.expectEqual(expected.len, @as(usize, @intCast(response.get("byte_count").?.integer)));
            const omitted = !capture or limit < expected.len;
            try std.testing.expectEqual(omitted, response.get("omitted").?.bool);
            if (omitted) try std.testing.expect(response.get("content_json").? == .null) else try std.testing.expectEqualStrings(expected, response.get("content_json").?.string);
        }
    }
}

test "observations failed and cancelled models have no completed response" {
    for ([_]@FieldType(ModelFinished, "outcome"){ .failed, .cancelled }) |outcome| {
        var collector = TestCollector{};
        defer collector.deinit();
        const sink = Sink{ .context = &collector, .emit_fn = TestCollector.emit, .options = .{ .enabled = true, .version = 4, .capture_content = true } };
        sink.finished(std.testing.allocator, .{ .trace = .{} }, .{ .model = "test", .outcome = outcome, .delivery = .definitely_unsent, .admitted = false, .output_text = null, .output_omitted = true, .output_sha256 = null, .output_byte_count = null }, &.{});
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, collector.data.?, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("model_finished").?.object.get("response").? == .null);
    }
}

test "observations preserve legacy model completion wire fields" {
    const value = ModelFinished{ .model = "test", .outcome = .completed, .delivery = .possibly_sent, .admitted = true, .output_text = null, .output_omitted = true, .output_sha256 = null, .output_byte_count = null };
    const expected = "{\"model\":\"test\",\"tool_call_ids\":[],\"outcome\":\"completed\",\"delivery\":\"possibly_sent\",\"admitted\":true,\"output_text\":null,\"output_omitted\":true,\"output_sha256\":null,\"output_byte_count\":null,\"usage\":null,\"error_type\":null}";
    for ([_]u8{ 1, 2, 3 }) |version| {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();
        try writeEventData(&out.writer, .{ .model_finished = value }, version);
        try std.testing.expectEqualStrings(expected, out.writer.buffered());
    }
}
