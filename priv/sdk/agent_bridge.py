"""Agent bridge: one headless `claude` session served as a Universe service.

Run by an agent worker (`serve` with an `agent` block). Starts

    claude -p --input-format stream-json --output-format stream-json --restricted ...

with the agent's purpose as its system prompt, then serves one function,
`task(prompt)`: the prompt goes in as a user message, the session's final
message comes back as the call's result. Calls arrive one at a time, so the
session is one conversation that remembers earlier tasks.

The session ID is saved so serving the agent again resumes it, and a task
past its caller's deadline is interrupted (see ``until_result``).

A reply starting with ``QUESTION:`` becomes ``U.ask``: the orchestrating
model sees the worker as asking, answers with a `reply` directive, and the
answer goes back into the session.

Config comes from the JSON file in ``UNIVERSE_AGENT_CONFIG``.
"""

import hashlib
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid

import universe as U

PROTOCOL = """

---
You are a worker agent run by Universe for an orchestrating agent. Each user \
message is one task from it. Do the task, then give the result as your final \
message: concise, complete, no preamble. That message is returned verbatim. \
You cannot run code or shell commands. If you cannot continue without \
information only the orchestrator has, reply with one line that starts with \
"QUESTION:" and nothing else; its answer comes back as the next message."""

cfg = json.load(open(os.environ["UNIVERSE_AGENT_CONFIG"]))
root = cfg["root"]


def permissions():
    # Absolute rule paths ("//abs/path"); Edit rules cover every file-writing
    # tool and Read rules every file-reading one (Grep, Glob too).
    roots = sorted({root, os.path.realpath(root)})
    allow = []
    if any(t in cfg["tools"] for t in ("Edit", "Write", "NotebookEdit")):
        for r in roots:
            for lease in cfg["leases"]:
                path = os.path.join(r, lease.strip("/")) if lease not in (".", "") else r
                allow += [f"Edit(/{path})", f"Edit(/{path}/**)"]
    deny = [f"{t}(/{r}/.universe/**)" for r in roots for t in ("Read", "Edit")]
    return {"permissions": {"allow": allow, "deny": deny}}


def command():
    args = [
        cfg["claude"], "-p",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--restricted", "--strict-mcp-config",
        "--permission-mode", "dontAsk",
        "--system-prompt", cfg["purpose"] + PROTOCOL,
        "--tools", ",".join(cfg["tools"]),
        "--settings", json.dumps(permissions()),
    ]
    if cfg.get("model"):
        args += ["--model", cfg["model"]]
    return args


# The session ID is kept in .universe/agents/<name>.json with a key of the
# agent's config, so serving the same agent again (after a kill, a crash or a
# daemon restart) resumes its conversation. A changed purpose, model, tools
# or leases, or "resume": false, starts a new one.
def config_key():
    shape = {k: cfg.get(k) for k in ("purpose", "model", "tools", "leases")}
    return hashlib.sha256(json.dumps(shape, sort_keys=True).encode()).hexdigest()[:16]


def saved_session_id():
    if not cfg.get("resume", True) or not cfg.get("session_file"):
        return None
    try:
        with open(cfg["session_file"]) as f:
            saved = json.load(f)
        return saved["session_id"] if saved.get("key") == config_key() else None
    except (OSError, ValueError, KeyError):
        return None


def save_session_id(sid):
    path = cfg.get("session_file")
    if not path:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump({"session_id": sid, "key": config_key()}, f)
    os.replace(path + ".tmp", path)


state = {"tasks": 0, "ctx": 0, "crashes": []}
session = {}


def start_session(resume):
    """Starts claude, resuming session["id"] if asked, else a new session."""
    if resume and session.get("id"):
        args = command() + ["--resume", session["id"]]
    else:
        session["id"] = str(uuid.uuid4())
        save_session_id(session["id"])
        args = command() + ["--session-id", session["id"]]
        resume = False
    proc = subprocess.Popen(args, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True, bufsize=1)
    events = queue.Queue()

    def pump():
        for line in proc.stdout:
            try:
                events.put(json.loads(line))
            except json.JSONDecodeError:
                pass
        events.put(None)

    threading.Thread(target=pump, daemon=True).start()
    # "confirmed" turns true at the first result: a resume that dies before
    # then (session gone) falls back to a new session.
    session.update(proc=proc, events=events, resumed=resume, confirmed=False)


def write(obj):
    session["proc"].stdin.write(json.dumps(obj) + "\n")
    session["proc"].stdin.flush()


def send(text):
    # A session that died (crash, killed) is resumed in a new process; more
    # than 3 deaths in 60 s ends the agent.
    if session["proc"].poll() is not None:
        now = time.time()
        state["crashes"] = [t for t in state["crashes"] if now - t < 60] + [now]
        if len(state["crashes"]) > 3:
            print("claude session died 4 times in 60s; giving up", file=sys.stderr, flush=True)
            threading.Timer(0.5, os._exit, [3]).start()
            raise RuntimeError("claude session keeps dying; the agent stops")
        start_session(resume=True)
        state["note"] = "session restarted"
    write({"type": "user", "message": {"role": "user", "content": text}})


class SessionEnded(Exception):
    pass


def until_result():
    """The next result. Past the caller's deadline the turn is interrupted."""
    interrupted_at = None
    while True:
        left = U.time_left()
        if interrupted_at is None and left is not None and left <= 1.0:
            write({"type": "control_request", "request_id": f"int-{uuid.uuid4().hex[:8]}",
                   "request": {"subtype": "interrupt"}})
            interrupted_at = time.time()
        if interrupted_at and time.time() - interrupted_at > 15:
            session["proc"].kill()
            raise TimeoutError("task timed out; the session did not stop, so it was restarted")
        try:
            e = session["events"].get(timeout=0.5)
        except queue.Empty:
            continue
        if e is None:
            code = session["proc"].wait()
            raise SessionEnded(f"claude session ended (exit {code})")
        if e.get("type") == "assistant" and not e.get("parent_tool_use_id"):
            u = e.get("message", {}).get("usage") or {}
            ctx = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + \
                u.get("cache_creation_input_tokens", 0)
            if ctx:
                state["ctx"] = ctx
        elif e.get("type") == "result":
            session["confirmed"] = True
            if interrupted_at:
                raise TimeoutError("task timed out; the agent stopped it and is idle again")
            return e


def idle_line():
    note = state.get("note")
    if not state["tasks"]:
        return "idle · " + (note or "ready")
    line = f"idle · {state['tasks']} tasks done · context {state['ctx'] / 1000:.1f}k tokens"
    return line + (f" · {note}" if note else "")


def task(prompt=None):
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("task needs a prompt")
    state["tasks"] += 1
    n, started = state["tasks"], time.time()
    U.progress(f"busy · task {n}: {' '.join(prompt.split())[:80]}")
    try:
        send(prompt)
        while True:
            try:
                result = until_result()
            except SessionEnded as exc:
                if session["resumed"] and not session["confirmed"]:
                    # The saved session could not be resumed: start anew.
                    start_session(resume=False)
                    state["note"] = "saved session lost; new session"
                    send(prompt)
                    continue
                raise RuntimeError(f"{exc}; the next task resumes it") from None
            text = (result.get("result") or "").strip()
            if result.get("is_error"):
                raise RuntimeError(text or result.get("subtype") or "agent error")
            if text.startswith("QUESTION:"):
                answer = U.ask(text[len("QUESTION:"):].strip())
                send(f"Answer from the orchestrator: {answer}")
                continue
            print(f"task {n} done in {time.time() - started:.1f}s · "
                  f"{result.get('num_turns', '?')} turns", flush=True)
            return text
    finally:
        U.progress(idle_line())


session["id"] = saved_session_id()
start_session(resume=session["id"] is not None)
if session["resumed"]:
    state["note"] = "resumed its earlier session"
U.progress(idle_line())
U.serve(cfg["service"], {"task": task}, describe="agent: " + " ".join(cfg["purpose"].split())[:120])
