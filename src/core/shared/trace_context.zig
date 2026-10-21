//! Optional host-owned W3C context. It is never persisted or inferred from content.
const std = @import("std");
const io_mod = @import("io.zig");

pub const TraceContext = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: [16]u8,
    flags: [2]u8,
    state: [512]u8 = @splat(0),
    state_len: u16 = 0,

    pub fn parse(parent: []const u8, state: ?[]const u8) !TraceContext {
        if (parent.len != 55 or !std.mem.eql(u8, parent[0..3], "00-") or parent[35] != '-' or parent[52] != '-') return error.InvalidTraceContext;
        if (!validId(parent[3..35]) or !validId(parent[36..52]) or !hex(parent[53..55])) return error.InvalidTraceContext;
        var result: TraceContext = .{ .trace_id = parent[3..35].*, .span_id = parent[36..52].*, .parent_span_id = parent[36..52].*, .flags = parent[53..55].* };
        if (state) |value| {
            if (value.len > result.state.len) return error.InvalidTraceContext;
            for (value) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidTraceContext;
            @memcpy(result.state[0..value.len], value);
            result.state_len = @intCast(value.len);
        }
        return result;
    }

    pub fn child(parent: TraceContext) TraceContext {
        var result = parent;
        result.parent_span_id = parent.span_id;
        var bytes: [8]u8 = undefined;
        while (true) {
            io_mod.getIo().random(&bytes);
            result.span_id = std.fmt.bytesToHex(bytes, .lower);
            if (validId(&result.span_id)) return result;
        }
    }

    pub fn traceparent(self: TraceContext) [55]u8 {
        var value: [55]u8 = undefined;
        @memcpy(value[0..3], "00-");
        @memcpy(value[3..35], &self.trace_id);
        value[35] = '-';
        @memcpy(value[36..52], &self.span_id);
        value[52] = '-';
        @memcpy(value[53..55], &self.flags);
        return value;
    }

    pub fn tracestate(self: *const TraceContext) ?[]const u8 {
        return if (self.state_len == 0) null else self.state[0..self.state_len];
    }

    pub fn wire(self: *const TraceContext) struct { trace_id: []const u8, span_id: []const u8, parent_span_id: []const u8 } {
        return .{ .trace_id = &self.trace_id, .span_id = &self.span_id, .parent_span_id = &self.parent_span_id };
    }
};

fn hex(value: []const u8) bool {
    for (value) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn validId(value: []const u8) bool {
    return hex(value) and !std.mem.allEqual(u8, value, '0');
}

test "host trace contexts preserve root identity and generate distinct children" {
    const root = try TraceContext.parse("00-0123456789abcdef0123456789abcdef-0123456789abcdef-01", "vendor=value");
    const first = root.child();
    const second = root.child();
    try std.testing.expectEqualStrings(&root.trace_id, &first.trace_id);
    try std.testing.expectEqualStrings(&root.span_id, &first.parent_span_id);
    try std.testing.expect(!std.mem.eql(u8, &first.span_id, &second.span_id));
    const carrier = first.traceparent();
    const parsed = try TraceContext.parse(&carrier, first.tracestate());
    try std.testing.expectEqualStrings(&first.span_id, &parsed.span_id);
    try std.testing.expectEqualStrings("vendor=value", parsed.tracestate().?);
    try std.testing.expectError(error.InvalidTraceContext, TraceContext.parse("00-00000000000000000000000000000000-0123456789abcdef-01", null));
    try std.testing.expectError(error.InvalidTraceContext, TraceContext.parse(&carrier, "bad\r\nstate"));
}
