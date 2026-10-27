# ACP session removal

ACP hosts using the default filesystem session store can remove saved history
with `session/remove`:

```json
{"jsonrpc":"2.0","id":1,"method":"session/remove","params":{"sessionId":"the-session-id"}}
```

A successful reply contains `{}` after the exact session and its marked direct
subagent children are removed and the sessions directory is synced. Repeating
removal of an absent ID also syncs the directory and succeeds. Active prompts,
busy writers, and sessions from another workspace are refused. Removal is
unavailable with the opt-in v2 store.

`session/close` releases the active conversation while retaining saved history.
