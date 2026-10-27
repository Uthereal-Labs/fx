# ACP session removal

ACP hosts using either filesystem session store can remove saved history
with `session/remove`:

```json
{"jsonrpc":"2.0","id":1,"method":"session/remove","params":{"sessionId":"the-session-id"}}
```

A successful reply contains `{}` after the exact session and its owned direct
subagent children are removed and the affected directories are synced. Repeating
a completed removal succeeds. Active prompts, busy writers, and sessions from
another workspace are refused.

With `FX_SESSIONS_V2=1`, removal verifies the root and every direct child's
current workspace and parent identity before changing any of them. It removes
their terminal state and session files while their native records still prove
ownership, then uses the v2 trash, index, and purge sequence. Interrupted removal
can be retried with the same session ID. Unverifiable ownership, orphaned outside
files without a native record, and nested children are refused. The current
subagent tool creates only direct children. A v2 removal also refuses a retained
v1 folder with the same ID.

`session/close` releases the active conversation while retaining saved history.
