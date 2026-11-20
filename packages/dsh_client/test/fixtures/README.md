# Fixtures

Frames captured live from `dsh web` 0.2.0-rc.2 (isolated temp `DSH_HOME`,
model `deepseek-official/deepseek-flash`) on 2026-10-23, then redacted:
temp paths -> `/tmp/dsh-home`, home -> `/home/user`, system prompt and tool
schemas truncated, the local skill catalog replaced by `example-skill`.
No tokens, cookies or API keys appear in any file.

| File | Content |
|---|---|
| `follow_reply_ok.jsonl` | `session/follow` items (`assistantStream: true`) for "reply with OK" |
| `follow_reply_ok_no_assistant_stream.jsonl` | same turn, second follow without `assistantStream` |
| `follow_approval_with_resync.jsonl` | bash `echo hi` with escalation: approval, tool call/result; the client forced a reconnect mid-stream, so a second snapshot with `activeAttempt` follows |
| `follow_cancel.jsonl` | `session/cancel` mid-stream: `interrupted: true`, `turn/end` aborted/user |
| `follow_blank_session.jsonl` | snapshot of a new session, rename and model selection events |
| `events_*.jsonl` | `$events` items: ready, `api-session/*`, `credentials/*`, `settings/*`, approval waterfall |
| `control_reply_ok.jsonl` | `session/control` baseline + projection frames |
| `workspace_follow.jsonl` | `workspace/follow` frames incl. archive/unarchive |
| `rpc_exchanges.json` | unary responses (list/create/catalog/credentials/errors) |
| `mux_raw_approval.jsonl` | raw mux frames in both directions for the approval turn |
| `follow_presented.jsonl` | synthetic (not captured): `present` calls and `deliverables/presented` events in the 0.2.1-rc.2 shape, incl. a re-declaration, a relative path and malformed entries; regenerate with `make_follow_presented.py` |

Each `.jsonl` line is one stream item `value` (or one raw frame for `mux_raw_*`).
