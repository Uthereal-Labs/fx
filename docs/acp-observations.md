# ACP observations

An embedding host can observe model attempts, tool execution, and tool-result preparation through
`fx/observation` notifications. fx sends these notifications only after an
explicit opt-in on `initialize`:

```json
{
  "protocolVersion": 1,
  "clientCapabilities": {},
  "_meta": {
    "fx": {
      "observations": {
        "version": 1,
        "capture_content": true,
        "max_content_bytes": 262144
      }
    }
  }
}
```

A successful response acknowledges `_meta.fx.observations.version: 1`. Without
that acknowledgement, the host must not claim that the connection provides this
observation contract. Options are connection-scoped and do not persist in a
session. Content capture defaults to `false`. The maximum content size defaults
to 262,144 bytes and must be between 1 and 1,048,576 bytes.

Each notification has `version`, a connection-local increasing `sequence`, the
native `session_id`, `turn_id`, `step_id`, `attempt`, `timestamp_ms`, and an
`event` containing `kind` and `data`. Model attempts have an integer `attempt`;
tool preparation uses `null` and correlates through the step and tool-call ID.
The host attaches its own run and trace identity to the connection.

| Event kind | Data |
| --- | --- |
| `model.request` | Model name, available tool names, request body and content digests, lengths, a visible-text projection, and preceding tool-call IDs. |
| `model.finished` | Model name, completion outcome, delivery certainty, admission status, returned tool-call IDs, bounded assistant text, optional input/output usage, and a fixed error type. |
| `tool.prepared` | Tool name and call ID, original result digest/length, actual model-visible text digest/length, truncation status, and optional stored-result handle. |

The model request hook runs at provider invocation after runtime projection and
compaction. It does not observe speculative request builds used for capacity
checks. `request.sha256` and `request.byte_count` identify the serialized provider
body when that body is supplied by the runtime; both are `null` otherwise.

`request.content_json` is labelled `visible_text_no_reasoning`. It contains the
effective instruction and conversation text, tool-call IDs, names, and arguments.
It also contains the available tool definitions from the serialized body, tool
choice, output token limit, and resolved model parameters. Available tool names
remain in metadata when content capture is off.
It excludes provider replay, hidden reasoning, images, credentials, HTTP headers,
and transport configuration. It is a projection, not a copy of the wire body.
`content_sha256` identifies this projection independently of the wire digest.

Capture limits omit the whole content field rather than returning an unmarked
prefix. The digest and byte count remain available. Request and tool projections
have an explicit `omitted` flag; assistant output uses `output_omitted` and retains
its own digest and length. Content can contain user or source material, so the
host controls whether its configured tracing destination may receive it.

Tool preparation observations describe what the model receives after managed
result storage. A complete ACP tool-call update can contain the original result
while the model receives a preview and retrieval handle. These are separate
surfaces. Observations do not grant `read_tool_result` or change tool permissions.

The notifications are a side channel. Hosts must handle them separately from
session updates and public conversation journals. Export failures do not change
model invocation or tool execution. Hosts should close incomplete generation
observations when the connection ends without a matching `model.finished`.

## Exact native parents with version 2

Request version 2 and pass the host-owned run context to connect native tools,
model attempts, and downstream operations to one trace:

```json
{
  "version": 2,
  "capture_content": true,
  "max_content_bytes": 524288,
  "traceparent": "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01",
  "tracestate": "vendor=value"
}
```

Place this object at `initialize._meta.fx.observations`. The response acknowledges
version 2. Unsupported observation versions and invalid trace contexts disable
observations without changing the ACP operation. Version 1 retains its existing
notification shape. Neither version stores trace state in session history.

Every version 2 envelope adds `trace` with `trace_id`, `span_id`, and
`parent_span_id`, represented as lowercase hexadecimal strings. fx generates a
new nonzero 64-bit span ID for each native tool execution and model attempt.
Start and finish events share that ID. The host exports each span using its
native ID and validates that it belongs to the supplied run trace. Repeated tool
call IDs do not reuse span IDs.

| Additional event | Data |
| --- | --- |
| `tool.started` | `tool_call_id`, `tool_name`, bounded `arguments_json`, `arguments_sha256`, `arguments_byte_count`, and `arguments_omitted`. |
| `tool.finished` | `tool_call_id`, `tool_name`, `outcome`, bounded `output_text`, `output_sha256`, `output_byte_count`, `output_omitted`, and `error_type`. |

Tool outcomes are `completed`, `failed`, or `cancelled`. A returned native result
finishes after managed output preparation; thrown failures finish immediately.
The `tool.prepared` envelope identifies its owning tool span. Original tool
output and the model-visible projection remain distinct fields and events.
Hosts close incomplete spans if native execution ends before a finish event.

Both MCP engines copy the tool context into each `tools/call` request's `_meta`
as `traceparent` and optional `tracestate`. Existing protocol and progress
metadata remain intact through retries and input-response continuations. A host
can pass static run headers for connection setup and discovery separately.

The configured Chat Completions transport sends the model attempt's context in
HTTP `traceparent` and optional `tracestate` headers. An authenticated local model
adapter can extract that parent before creating its transport span. These headers
are separate from the model body, so they do not alter request-body digests.
The tracing contract carries no exporter credentials.

## Delegated execution with version 3

Request `version: 3` with the same trace and capture options to observe delegated
children. Require the version 3 acknowledgement before consuming this contract.
Each envelope adds a required `work_id`: `null` for root events and the native
work identity for child events. `session_id` identifies the emitting root or
child session. The sequence remains connection-wide across concurrent children.

| Additional event | Data |
| --- | --- |
| `child.started` | `root_session_id`, `parent_session_id`, and the originating `tool_call_id`. |
| `child.finished` | `outcome` (`completed`, `failed`, or `cancelled`) and nullable `error_type`. |

The lifecycle envelopes identify a fresh child execution span parented to the
exact native `subagent` tool span. Both use `turn_id: 0`, `step_id: 0`, and
`attempt: null`. Registration precedes worker startup; completion follows the
worker's final native observation. A startup failure after registration emits a
failed completion. A yielded parent receipt leaves the child span open until
the worker finishes. Replaying completed work creates no worker or child span.

Child model attempts and tools retain their own native coordinates and parent
to the child execution span. Model HTTP headers identify the exact model span;
MCP call metadata identifies the exact tool span. Trace state belongs to the
live worker and is never written into session or queued-work records. A resumed
execution uses the current connection's trace context.

Hosts should bind the root session from the successful ACP session operation,
register children only beneath an observed delegation call, and validate each
child's session, work identity, and ancestry. Current delegation permits direct
root children. Unknown children, sequence gaps, unmatched completions, and
unfinished descendants prevent a complete trace. Only root model output should
update the root answer. Hosts with an authenticated model adapter can also
compare its admitted calls with native observations to detect a missing stream.

## Current assistant responses with version 4

Request `version: 4` with the same trace and capture options, and require the
version 4 acknowledgement. Version 4 retains version 3's delegated execution
and adds `response` to every `model.finished` payload. Versions 1 through 3
retain their existing notification fields.

For a completed model request, `response` contains:

| Field | Meaning |
| --- | --- |
| `content_json` | A JSON assistant message with `role: "assistant"`, nullable `content`, and `tool_calls`. Each call contains only `id`, `name`, and its exact `arguments_json` string. |
| `sha256` | SHA-256 of the complete UTF-8 assistant-message projection. |
| `byte_count` | Length of that projection in bytes, before any content omission. |
| `omitted` | Whether capture is disabled or the whole projection exceeds `max_content_bytes`. When true, `content_json` is `null`. |
| `content_projection` | The fixed value `assistant_message_no_reasoning`. |

fx captures the finalized provider completion before orchestration or tool
execution. The message describes only the current completion; preceding tool
results and conversation turns remain in `model.request`. Tool-only completions
retain their calls with nullable text. Invalid argument strings remain unchanged
so a host never mistakes an invented empty object for the model's output.
Provider replay, hidden reasoning, provider-side tool results, and transport
state are excluded. The complete projection is omitted as one field when it
does not fit; individual calls are never silently removed.

For failed or cancelled requests, `response` is `null`. The existing
`output_text`, `output_sha256`, `output_byte_count`, and `output_omitted` fields
continue to describe assistant text independently. The response digest identifies
the safe projection, not a raw provider response or a request-body digest.

Hosts can translate the projected messages into their tracing backend's chat
format without changing model inputs or tool arguments. For example, a tracing
backend that expects OpenAI-style calls can map `name` and `arguments_json` to
`function.name` and `function.arguments`, retaining each call's `id`.

## Verify the built binary

Build from the repository root, then run the provider-free driver:

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/test-acp-observations.py
```

The driver uses `zig-out/bin/fx`, isolated temporary homes, and loopback fake HTTP
and MCP servers. It compares request digests with actual received HTTP bodies,
checks the managed preview against the model-facing tool message, verifies
hidden reasoning exclusion, and exercises opt-in and capture limits. It also
checks that private observations and session-scoped `libfx/hook` events can be
enabled independently or used together. It makes
no external model calls. Version 2 checks exact native parents in both MCP
engines, model HTTP headers, content opt-out, and invalid-context fallback. Write
an actual version 2 capture with `--observations-v2-output /tmp/fx-observations.v2.json`.
The multi-call case checks separate MCP receipts;
dynamic MCP tools execute sequentially in this fixture. It does not exercise
the runtime's parallel builtin-tool branch in the version 2 case.

Version 3 and 4 cases exercise concurrent native children, cold MCP discovery on both
engines, exact model and MCP parents, child steering, completed-work replay, and
cancellation. Managed-owner tests cover trace context across yielded work.
Save an actual child capture with
`--observations-v3-output /tmp/fx-observations.v3.json`.
Version 4 also checks current tool calls, content limits, and the retained legacy
fields. Save an actual version 4 child capture with
`--observations-v4-output /tmp/fx-observations.v4.json`.

Focused native unit tests can run with:

```sh
zig build test -Doptimize=ReleaseSafe -Dtest-filter=observations
```
