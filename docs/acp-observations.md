# ACP observations

An embedding host can observe model attempts and tool-result preparation through
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

## Verify the built binary

Build from the repository root, then run the provider-free driver:

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/test-acp-observations.py
```

The driver uses `zig-out/bin/fx`, isolated temporary homes, and loopback fake HTTP
and MCP servers. It compares request digests with actual received HTTP bodies,
checks the managed preview against the model-facing tool message, verifies
hidden reasoning exclusion, and exercises opt-in and capture limits. It makes
no external model calls. The multi-call case checks separate MCP receipts;
dynamic MCP tools execute sequentially in this fixture. It does not exercise
the runtime's parallel builtin-tool branch.

Focused native unit tests can run with:

```sh
zig build test -Doptimize=ReleaseSafe -Dtest-filter=observations
```
