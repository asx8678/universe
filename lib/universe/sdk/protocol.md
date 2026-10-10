# Universe SDK protocol

How a worker's code talks to the daemon. `priv/sdk/universe.py` and
`priv/sdk/universe.exs` implement it; this is for anyone writing another
client.

## Transport

- A Unix socket, path in `UNIVERSE_SOCK`: `.universe/sdk.sock` (mode 0600),
  or `$TMPDIR/universe-<hash>.sock` when the project path would go past
  macOS's 104-byte limit. The sandbox profile allows connecting to that one
  socket and nothing else.
- Newline-delimited JSON in both directions, one object per line, UTF-8.
- A worker gets its ID in `UNIVERSE_ID` and its token in `UNIVERSE_TOKEN` or
  in the file named by `UNIVERSE_TOKEN_FILE`. The token is valid only while
  that worker lives.

## Handshake

The first line must be

```json
{"rid":0,"op":"hello","id":5,"token":"..."}
```

A wrong ID or token gets `{"ok":false,"error":"bad credentials"}`, and
every request before a good `hello` gets `"send hello first"`.

## Requests (worker → daemon)

Each request carries a `rid`, which the reply echoes:
`{"rid":1,"ok":true,"result":...}` or `{"rid":1,"ok":false,"error":"..."}`.

| op | fields | result |
|---|---|---|
| `put` | `name`, `value`, optional `kind` (`table`, `json`, `text`) | handle `h:<id>/<name>` |
| `put_file` | `name`, `path` (in the project or the worker's run dir) | handle |
| `get` | `handle` | the value; file handles as `{"base64": "..."}` |
| `progress` | `text` | `null`; sets the worker's digest line |
| `ask` | `question` | the model's answer (blocks until a `reply` directive) |
| `call` | `service`, `fn`, `args`, optional `timeout_s` (default 60, max 1800) | the function's return value |
| `serve` | `name`, `fns` (list of names), `describe` | `null`; the connection is now the service |

## Invocations (daemon → service)

After `serve`, the daemon sends calls to the service one at a time:

```json
{"op":"invoke","cid":9,"fn":"query","args":{"sql":"select 1"},"timeout_ms":59000}
```

`timeout_ms` is what is left of the caller's timeout (the Python client
exposes it as `U.time_left()`); an invocation whose caller gave up while it
was queued is never sent.

The service answers with
`{"op":"result","cid":9,"ok":true,"value":...}` or
`{"op":"result","cid":9,"ok":false,"error":"..."}`. Replies to its own
requests can arrive while an invocation is pending; a client must buffer
`invoke` lines it reads while waiting for a `rid` reply (the Python client
does).

`args` that are an object are passed as keyword arguments by the bundled
clients, a list as positional arguments, `null` as none.

## Limits

- A line may be up to 72 MB; handle values up to 64 MB.
- Closing the connection unregisters the worker's service; the worker
  itself is stopped by its process exiting, not by the socket.
