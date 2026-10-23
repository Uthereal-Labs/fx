# Short saved-result handles

Set `short_tool_result_handles` to `true` in your profile's `settings.json` to use short handles in newly stored tool-result previews:

```json
{
  "short_tool_result_handles": true
}
```

The setting defaults to `false`. Project `.fx.json` files cannot enable it. Root agents and their children inherit the profile policy. Existing native handles remain readable, and turning the setting off does not invalidate aliases already issued.

A short handle has the form `F<session-id>:<ordinal>`, for example `FabcDEF123_-x:1`. The owner is the exact native session ID, not a shortened hash. A child's handle cannot resolve through its parent's store. Ordinals start at 1 and are never reused within the owner. Repeated admission of the same physical result reuses its alias. A fork gets its own owner namespace.

Pass the complete handle to `read_tool_result`. Range and literal-query responses echo it unchanged. Unknown, foreign, or malformed aliases fail; they do not trigger a command-replay lookup. A handle identifies a stored result and does not grant access to another session or establish citation authority.

Physical result handles, blobs, artifact references, content checks, byte ranges, and completeness flags remain unchanged. Aliases are presentation metadata held in `tool-result-aliases-<session-id>.json`: an atomic private sidecar for legacy sessions or a named blob record for current sessions. The existing session batch lists the blob record before the corresponding tool result becomes durable. The mapping survives restart and compaction. Live and resumed previews use the same alias without rewriting native history.

Each owner can register 4,096 results, within a 1 MiB mapping envelope. Exhaustion or an invalid mapping fails explicitly instead of recycling an alias or exposing a different result. Older results without an alias retain their original native handles.

Legacy session creation temporarily replays history before its directory receives the native session ID. Physical previews remain readable during that step when no alias registry exists. Registration and resolution still require an exact valid owner; an existing registry never receives this fallback.

The focused native tests cover owner separation, concurrent duplicate admission, reopening, retained-turn compaction, physical-byte preservation, range/query echoes, and rejection without command-replay fallback. The `sessions-v2.test.ts` scenario `short saved-result aliases preserve physical blobs and resume after profile opt-out` exercises the built binary through a local fake gateway. It makes no provider calls.
