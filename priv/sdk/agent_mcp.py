"""Universe services as MCP tools for an agent worker (stdio, standard library only).

The agent bridge lists this server in its claude session's ``--mcp-config``.
It connects to the Universe SDK socket as the agent's own worker ID (with the
agent's token file) and offers one tool per function of each service named in
``UNIVERSE_AGENT_SERVICES``, called ``<service>__<function>``, plus
``handle_preview``. The kernel refuses calls to any other service, so this
server is a convenience, not the boundary.

Each tool call opens its own SDK connection, so parallel calls never share a
socket. A result over MAX_INLINE characters is stored as a handle under the
agent's ID and comes back as that handle and its preview, so big data stays
out of the agent's context the way it stays out of the orchestrator's.
"""

import itertools
import json
import os
import re
import socket
import sys
import threading

SERVER = "services"
# The API takes tool names up to 64 chars, and Claude Code prefixes ours.
MAX_TOOL_NAME = 64 - len(f"mcp__{SERVER}__")
MAX_INLINE = 8000
CALL_TIMEOUT_S = int(os.environ.get("UNIVERSE_AGENT_CALL_TIMEOUT_S", "300"))
SERVICES = [s for s in os.environ.get("UNIVERSE_AGENT_SERVICES", "").split(",") if s]
VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
# Claude Code defers MCP tools behind tool search unless marked.
ALWAYS_LOAD = {"anthropic/alwaysLoad": True}

INSTRUCTIONS = (
    "These tools are services the orchestrator started for your work, named "
    "<service>__<function>. Small results come back inline. A large result comes "
    "back as a handle (h:<id>/<name>) with a preview: pass the handle to a service "
    "function that takes one, or look again with handle_preview. A failed call "
    "returns the error as its result; fix the arguments and try again."
)

PREVIEW_TOOL = {
    "name": "handle_preview",
    "description": "Preview a Universe handle (h:<id>/<name>): a table's columns, row "
    "count and first rows, a JSON value's keys, or the head of a text.",
    "inputSchema": {
        "type": "object",
        "properties": {"handle": {"type": "string", "description": "h:<id>/<name>"}},
        "required": ["handle"],
    },
    "_meta": ALWAYS_LOAD,
}


class SdkError(Exception):
    """A request Universe refused, or a service call that failed."""


class Sdk:
    """One SDK connection, authenticated as this agent."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(os.environ["UNIVERSE_SOCK"])
        self.reader = self.sock.makefile("rb")
        self.rid = 0
        with open(os.environ["UNIVERSE_TOKEN_FILE"]) as f:
            token = f.read().strip()
        self.request("hello", id=int(os.environ["UNIVERSE_ID"]), token=token)

    def request(self, op, **fields):
        self.rid += 1
        line = json.dumps(dict(fields, op=op, rid=self.rid), separators=(",", ":"))
        self.sock.sendall(line.encode("utf-8") + b"\n")
        while True:
            raw = self.reader.readline()
            if not raw:
                raise SdkError("connection to Universe closed")
            msg = json.loads(raw)
            if msg.get("rid") == self.rid:
                if msg.get("ok"):
                    return msg.get("result")
                raise SdkError(msg.get("error") or "request failed")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def sdk(op, **fields):
    conn = Sdk()
    try:
        return conn.request(op, **fields)
    finally:
        conn.close()


routes = {}  # tool name -> (service, fn)
routes_lock = threading.Lock()
counter = itertools.count(1)


def safe(text):
    return re.sub(r"[^A-Za-z0-9_-]", "_", text)


def unique(name, taken):
    candidate, n = name, 2
    while candidate in taken or candidate == PREVIEW_TOOL["name"]:
        suffix = f"_{n}"
        candidate = name[: MAX_TOOL_NAME - len(suffix)] + suffix
        n += 1
    taken.add(candidate)
    return candidate


def schema(sig):
    if not sig:
        return {"type": "object", "additionalProperties": True}
    return {
        "type": "object",
        "properties": {p: {} for p in sig.get("params") or []},
        "required": sig.get("required") or [],
        "additionalProperties": bool(sig.get("extra")),
    }


def description(service, describe, fn, sig):
    doc = (sig or {}).get("doc") or ""
    text = f"{fn} of the {service} service" + (f": {doc}" if doc else ".")
    if not sig:
        text += f" Pass {fn}'s keyword arguments."
    if describe:
        text += f" ({service}: {describe})"
    return text[:1024]


def build_tools():
    """One tool per function of each live service this agent was given."""
    tools, new_routes, taken = [], {}, set()
    for info in sdk("services", names=SERVICES):
        if not info.get("live"):
            continue
        service, describe = info["name"], info.get("describe") or ""
        for fn in info.get("fns") or []:
            sig = (info.get("sigs") or {}).get(fn)
            name = unique(safe(f"{service}__{fn}")[:MAX_TOOL_NAME], taken)
            tools.append({
                "name": name,
                "description": description(service, describe, fn, sig),
                "inputSchema": schema(sig),
                "_meta": ALWAYS_LOAD,
            })
            new_routes[name] = (service, fn)
    with routes_lock:
        routes.clear()
        routes.update(new_routes)
    return tools + [PREVIEW_TOOL]


def call_tool(name, args):
    if name == PREVIEW_TOOL["name"]:
        return sdk("preview", handle=str(args.get("handle", "")))
    with routes_lock:
        route = routes.get(name)
    if route is None:
        build_tools()
        with routes_lock:
            route = routes.get(name)
    if route is None:
        raise SdkError(f"no tool {name}: its service is not running")
    service, fn = route
    value = sdk("call", service=service, fn=fn, args=args, timeout_s=CALL_TIMEOUT_S)
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    if len(text) <= MAX_INLINE:
        return text
    handle = sdk("put", name=safe(f"{fn}-{next(counter)}")[:64], value=value)
    return (f"The result is large ({len(text):,} chars), so it is stored as {handle}. "
            f"Preview:\n{sdk('preview', handle=handle)}")


out_lock = threading.Lock()
cancelled = set()


def respond(mid, result=None, error=None):
    if mid in cancelled:
        cancelled.discard(mid)
        return
    msg = {"jsonrpc": "2.0", "id": mid}
    if error is None:
        msg["result"] = result
    else:
        msg["error"] = error
    line = json.dumps(msg, ensure_ascii=False)
    with out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def handle_call(mid, params):
    args = params.get("arguments")
    try:
        text = call_tool(params.get("name"), args if isinstance(args, dict) else {})
        respond(mid, {"content": [{"type": "text", "text": text}]})
    except Exception as exc:  # every call gets an answer
        respond(mid, {"content": [{"type": "text", "text": str(exc)}], "isError": True})


def main():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
        if method == "notifications/cancelled":
            rid = params.get("requestId")
            if isinstance(rid, (str, int)):
                # A cancel that comes after its answer was sent stays here;
                # keep the set small.
                if len(cancelled) > 1000:
                    cancelled.clear()
                cancelled.add(rid)
        elif mid is None:
            continue  # other notifications
        elif method == "initialize":
            wanted = params.get("protocolVersion")
            respond(mid, {
                "protocolVersion": wanted if wanted in VERSIONS else VERSIONS[0],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "universe-services", "version": "0.1.0"},
                "instructions": INSTRUCTIONS,
            })
        elif method == "tools/list":
            try:
                respond(mid, {"tools": build_tools()})
            except (SdkError, OSError, ValueError) as exc:
                respond(mid, error={"code": -32603, "message": f"Universe: {exc}"})
        elif method == "tools/call":
            threading.Thread(target=handle_call, args=(mid, params), daemon=True).start()
        elif method == "ping":
            respond(mid, {})
        else:
            # server/discover (2026-07-28) included: Claude Code falls back to initialize.
            respond(mid, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
