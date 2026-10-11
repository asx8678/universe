"""Universe SDK for Python workers (standard library only).

Every Python snippet and service gets this module pre-imported as ``U``
(``import universe`` works too). It talks to the Universe kernel over the
Unix socket in ``UNIVERSE_SOCK``.

    rows = U.call("pg", "query", {"sql": "select * from orders"})
    h = U.put("orders", rows)            # -> "h:5/orders"; only a preview reaches the model
    U.progress("scanned 800/1240")       # the line shown for this worker in the next digest
    answer = U.ask("Use the new tokens file?")   # blocks until the model replies

    def query(sql):
        ...
    U.serve("pg", {"query": query}, "Postgres reader for the orders DB")   # never returns

Service functions receive the call's ``args``: an object becomes keyword
arguments, a list becomes positional arguments, null means no arguments.
Return values must be JSON-serialisable (anything else is passed through
``str``). Large results belong in handles: ``return U.put("rows", rows)``.
``U.serve`` also sends each function's parameters and the first paragraph
of its docstring: an agent given the service gets them as its tool schema.
"""

import base64
import inspect as _inspect
import json
import time
import os
import socket
import traceback

__all__ = ["call", "put", "put_file", "get", "progress", "ask", "serve", "inbox", "UniverseError"]


class UniverseError(Exception):
    """A request the kernel refused or a service call that failed."""


_sock = None
_reader = None
_rid = 0
_pending_invokes = []


def _connect():
    global _sock, _reader
    if _sock is not None:
        return
    path = os.environ.get("UNIVERSE_SOCK")
    if not path:
        raise UniverseError("UNIVERSE_SOCK is not set: not running inside Universe")
    _sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    _sock.connect(path)
    _reader = _sock.makefile("rb")
    token = os.environ.get("UNIVERSE_TOKEN")
    if token is None:
        with open(os.environ["UNIVERSE_TOKEN_FILE"]) as f:
            token = f.read().strip()
    _send({"op": "hello", "id": int(os.environ["UNIVERSE_ID"]), "token": token})
    reply = _read()
    if not reply.get("ok"):
        raise UniverseError(reply.get("error", "hello refused"))


def _send(msg):
    try:
        text = json.dumps(msg, default=str, separators=(",", ":"), allow_nan=False)
    except ValueError:
        # JSON has no NaN or Infinity; Universe would reject the whole line.
        raise UniverseError("value contains NaN or Infinity, which JSON can't carry") from None
    _sock.sendall(text.encode("utf-8") + b"\n")


def _read():
    line = _reader.readline()
    if not line:
        raise UniverseError("connection to Universe closed")
    return json.loads(line)


def _request(op, **fields):
    global _rid
    _connect()
    _rid += 1
    rid = _rid
    _send(dict(fields, op=op, rid=rid))
    while True:
        msg = _read()
        if msg.get("op") == "invoke":
            _pending_invokes.append(msg)
            continue
        if msg.get("rid") == rid:
            if msg.get("ok"):
                return msg.get("result")
            raise UniverseError(msg.get("error", "request failed"))


def call(service, fn, args=None, timeout_s=None):
    """Call function ``fn`` of a running service and return its result."""
    fields = {"service": service, "fn": fn, "args": args}
    if timeout_s is not None:
        fields["timeout_s"] = int(timeout_s)
    return _request("call", **fields)


def put(name, value, kind=None):
    """Store a JSON value; returns its handle (``h:<id>/<name>``).

    kind is inferred: a list of dicts is a table, a str is text, anything
    else is json. Pass kind="table" | "json" | "text" to be explicit.
    """
    fields = {"name": name, "value": value}
    if kind is not None:
        fields["kind"] = kind
    return _request("put", **fields)


def put_file(name, path):
    """Copy a file (in the project or this run's directory) into a handle."""
    return _request("put_file", name=name, path=os.path.abspath(path))


def get(handle):
    """Read a handle's value. File handles come back as bytes."""
    value = _request("get", handle=handle)
    if isinstance(value, dict) and set(value) == {"base64"}:
        return base64.b64decode(value["base64"])
    return value


def progress(text):
    """Set the line shown for this worker in the next digest."""
    _request("progress", text=str(text))


def ask(question):
    """Ask the model a question; blocks until it replies, returns the answer."""
    return _request("ask", question=str(question))


def inbox():
    """Inside a service function: the model's steers for this call, if any.

    Each is ``{"text": ..., "interrupt": bool}`` and is returned once."""
    return _request("inbox") or []


_deadline = None


def time_left():
    """Inside a service function: seconds until the caller gives up, or None."""
    return None if _deadline is None else max(0.0, _deadline - time.monotonic())


def _signature(fn):
    """A service function's keyword parameters and docstring, or None."""
    try:
        sig = _inspect.signature(fn)
    except (TypeError, ValueError):
        return None
    params, required, extra = [], [], False
    for p in sig.parameters.values():
        if p.kind is p.POSITIONAL_ONLY:
            return None  # can't be passed by name, so no schema
        if p.kind is p.VAR_KEYWORD:
            extra = True
        elif p.kind is not p.VAR_POSITIONAL:
            params.append(p.name)
            if p.default is p.empty:
                required.append(p.name)
    doc = (_inspect.getdoc(fn) or "").split("\n\n")[0].strip()
    return {"params": params, "required": required, "doc": doc[:500], "extra": extra}


def serve(name, fns, describe=""):
    """Turn this process into the named service. Never returns."""
    if not isinstance(fns, dict) or not fns:
        raise UniverseError("serve needs a dict of function name -> callable")
    sigs = {fn: sig for fn, sig in ((fn, _signature(f)) for fn, f in fns.items()) if sig}
    _request("serve", name=name, fns=sorted(fns), describe=describe, sigs=sigs)
    while True:
        msg = _pending_invokes.pop(0) if _pending_invokes else _read()
        if msg.get("op") != "invoke":
            continue
        cid, fn_name, args = msg.get("cid"), msg.get("fn"), msg.get("args")
        global _deadline
        left = msg.get("timeout_ms")
        _deadline = time.monotonic() + left / 1000 if isinstance(left, (int, float)) else None
        try:
            fn = fns[fn_name]
            if isinstance(args, dict):
                value = fn(**args)
            elif isinstance(args, list):
                value = fn(*args)
            elif args is None:
                value = fn()
            else:
                value = fn(args)
            _send({"op": "result", "cid": cid, "ok": True, "value": value})
        except Exception as exc:  # report, keep serving
            detail = "".join(traceback.format_exception_only(type(exc), exc)).strip()
            _send({"op": "result", "cid": cid, "ok": False, "error": detail})
