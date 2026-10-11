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

The services in the agent's ``services`` list are its MCP tools: the bridge
writes an ``mcp.json`` for ``agent_mcp.py`` into the run dir. While a task
runs the bridge also fetches the model's `steer` directives (``U.inbox``)
and writes them into the session, which takes them in at its next tool step;
the task's answer is the first result once every steer was taken in (each
message comes back as an ``isReplay`` event when the session takes it).

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
"QUESTION:" and nothing else; its answer comes back as the next message. \
A message from the orchestrator can also arrive while you work; it changes \
or adds to the task in hand."""

SERVICES_NOTE = """ The orchestrator's services are your tools (mcp__services__*): \
use them for the data and actions they offer."""

cfg = json.load(open(os.environ["UNIVERSE_AGENT_CONFIG"]))
root = cfg["root"]
services = cfg.get("services") or []
SDK_DIR = os.path.dirname(os.path.abspath(U.__file__))
# Per service call from the agent's tools; Claude Code's own MCP timer gets more.
CALL_TIMEOUT_S = 300
STEER_POLL_S = 0.5
# After a result, how long a steer the session hasn't taken in yet may take to
# start its own turn (it starts at once: the message is already queued).
STEER_TURN_WAIT_S = 5.0


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
    if services:
        allow.append("mcp__services")
    return {"permissions": {"allow": allow, "deny": deny}}


def mcp_config():
    """agent_mcp.py, run as this worker: the agent's services as tools.

    No secrets in the file: the socket path, this worker's ID and the path of
    its token file, which the agent's own file tools can't read."""
    keep = ("UNIVERSE_SOCK", "UNIVERSE_ID", "UNIVERSE_TOKEN_FILE", "PATH", "LANG")
    env = {k: os.environ[k] for k in keep if k in os.environ}
    env.update(UNIVERSE_AGENT_SERVICES=",".join(services),
               UNIVERSE_AGENT_CALL_TIMEOUT_S=str(CALL_TIMEOUT_S))
    server = {
        "type": "stdio",
        "command": sys.executable,
        "args": ["-I", "-u", os.path.join(SDK_DIR, "agent_mcp.py")],
        "env": env,
        "timeout": (CALL_TIMEOUT_S + 30) * 1000,
        "alwaysLoad": True,
    }
    path = os.path.join(os.environ["UNIVERSE_RUN_DIR"], "mcp.json")
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"mcpServers": {"services": server}}, f)
    os.replace(path + ".tmp", path)
    return path


def command():
    args = [
        cfg["claude"], "-p",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--replay-user-messages",
        "--restricted", "--strict-mcp-config",
        "--permission-mode", "dontAsk",
        "--system-prompt", cfg["purpose"] + PROTOCOL + (SERVICES_NOTE if services else ""),
        "--tools", ",".join(cfg["tools"]),
        "--settings", json.dumps(permissions()),
    ]
    if services:
        args += ["--mcp-config", mcp_config()]
    if cfg.get("model"):
        args += ["--model", cfg["model"]]
    return args


# The session ID is kept in .universe/agents/<name>.json with a key of the
# agent's config, so serving the same agent again (after a kill, a crash or a
# daemon restart) resumes its conversation. A changed purpose, model, tools
# or leases, or "resume": false, starts a new one.
def config_key():
    shape = {k: cfg.get(k) for k in ("purpose", "model", "tools", "leases")}
    if services:
        shape["services"] = services
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


state = {"tasks": 0, "ctx": 0, "crashes": [], "calls": {}}
session = {}
# How long a resumed session gets to fail at boot ("No conversation found"
# comes within a second) before the agent says it is ready.
RESUME_CHECK_S = 2.5


def start_session(resume):
    """Starts claude, resuming session["id"] if asked, else a new session."""
    if resume and session.get("id"):
        args = command() + ["--resume", session["id"]]
    else:
        session["id"] = str(uuid.uuid4())
        save_session_id(session["id"])
        args = command() + ["--session-id", session["id"]]
        resume = False
    # Tool calls into services may take minutes (MCP's own timer is 60 s).
    env = dict(os.environ, MCP_TOOL_TIMEOUT=str((CALL_TIMEOUT_S + 30) * 1000))
    proc = subprocess.Popen(args, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True, bufsize=1, env=env)
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
    # "stray": a steer of the last task may still produce a result of its own.
    # "replays": the session has echoed a user message it took in, so a
    # prompt's echo can be waited for.
    session.update(proc=proc, events=events, resumed=resume, confirmed=False, stray=False,
                   replays=False)


def write(obj):
    session["proc"].stdin.write(json.dumps(obj) + "\n")
    session["proc"].stdin.flush()


def lost_resume():
    """True when a resumed session died before its first result: the saved
    session is gone (claude says "No conversation found"), so start anew."""
    return session["proc"].poll() is not None and session["resumed"] and not session["confirmed"]


def start_fresh():
    start_session(resume=False)
    state["note"] = "saved session lost; new session"


def send(text):
    if lost_resume():
        start_fresh()
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


def message_text(content):
    """A replayed user message's text: a string, or (another CLI's shape) a
    list of content blocks."""
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content if isinstance(b, dict))
    return content


# A session that has never echoed a user message may not echo at all: then
# an earlier task's leftover results are skipped for this long at most.
# Once it has echoed one, results are skipped until the prompt's echo.
EXPECT_WAIT_S = float(cfg.get("expect_wait_s") or 30)


def interrupt():
    write({"type": "control_request", "request_id": f"int-{uuid.uuid4().hex[:8]}",
           "request": {"subtype": "interrupt"}})


def steer_message(text):
    return f"Message from the orchestrator while you work on this task: {text}"


def write_steer(text, pending):
    msg = steer_message(text)
    write({"type": "user", "message": {"role": "user", "content": msg}})
    pending.append(msg)


def fetch_steers(pending, stopping):
    """Writes the model's steers for this task into the session. One that asks
    to interrupt stops the turn first; it and any steer after it wait in
    ``stopping`` for that turn's result."""
    try:
        steers = U.inbox()
    except U.UniverseError:
        return
    for steer in steers:
        text = " ".join(str(steer.get("text") or "").split())
        if not text:
            continue
        if steer.get("interrupt") and not stopping:
            interrupt()
        if steer.get("interrupt") or stopping:
            stopping.append(text)
        else:
            write_steer(text, pending)
        U.progress(f"busy · task {state['tasks']} · steered: {text[:80]}")


def until_result(expect=None):
    """The task's next result. Steers are written in as they come; a result
    with a steer not yet taken in waits for the turn that steer starts. Past
    the caller's deadline the turn is interrupted.

    With ``expect`` (the prompt just sent), results that come before the
    session takes that prompt in belong to an earlier task's leftover steer
    turn and are skipped. Steers aren't fetched while such a turn may run
    or while a result is held: left in the inbox, they are dropped and
    logged if the task ends first. Steers fetched but never delivered (the
    task timed out or the session ended) are reported as dropped."""
    stopping = []  # steers waiting for the turn they interrupted to end
    try:
        return _until_result(expect, stopping)
    except BaseException:
        if stopping:
            try:
                U.steers_dropped(stopping, "the task ended before the agent took them in")
            except U.UniverseError:
                pass
        raise


def _until_result(expect, stopping):
    interrupted_at = None
    expect_until = time.time() + EXPECT_WAIT_S
    pending = []   # steers written, not yet taken in by the session
    held = None    # a result a pending steer's own turn may still replace
    held_at = 0.0
    next_poll = 0.0
    while True:
        now = time.time()
        left = U.time_left()
        if expect is not None and not session["replays"] and now > expect_until:
            expect = None  # this session doesn't echo; don't skip forever
            session["stray"] = False
        if held is not None and (now - held_at > STEER_TURN_WAIT_S
                                 or (left is not None and left <= 1.5)):
            # The steer never started a turn yet; if it does later, its
            # result must not become the next task's answer.
            session["stray"] = True
            return held
        if interrupted_at is None and left is not None and left <= 1.0:
            interrupt()
            interrupted_at = now
        if interrupted_at and now - interrupted_at > 15:
            session["proc"].kill()
            try:
                session["proc"].wait(timeout=5)  # reaped, so the next task restarts it
            except subprocess.TimeoutExpired:
                pass
            raise TimeoutError("task timed out; the session did not stop, so it was restarted")
        if interrupted_at is None and expect is None and held is None and now >= next_poll:
            next_poll = now + STEER_POLL_S
            fetch_steers(pending, stopping)
        try:
            e = session["events"].get(timeout=0.25)
        except queue.Empty:
            continue
        if e is None:
            code = session["proc"].wait()
            raise SessionEnded(f"claude session ended (exit {code})")
        if e.get("type") == "user" and e.get("isReplay"):
            session["replays"] = True
            content = message_text((e.get("message") or {}).get("content"))
            if expect is not None and content == expect:
                expect = None
                session["stray"] = False
            elif content in pending:
                pending.remove(content)
                # Taken in after a result: it started a turn of its own,
                # whose result is the task's answer.
                held = None
        elif e.get("type") == "assistant":
            msg = e.get("message", {})
            u = msg.get("usage") or {}
            ctx = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + \
                u.get("cache_creation_input_tokens", 0)
            # Every model call once (stream-json repeats a message per block).
            state["calls"][msg.get("id") or id(e)] = ctx + u.get("output_tokens", 0)
            if ctx and not e.get("parent_tool_use_id"):
                state["ctx"] = ctx
        elif e.get("type") == "result":
            session["confirmed"] = True
            if expect is not None:
                continue  # an earlier task's steer turn
            if interrupted_at:
                if pending:
                    session["stray"] = True
                raise TimeoutError("task timed out; the agent stopped it and is idle again")
            if stopping:
                # The turn a steer interrupted: its steers go in as the next turn.
                for text in stopping:
                    write_steer(text, pending)
                stopping.clear()
                held = None
                continue
            if pending:
                held, held_at = e, time.time()
                continue
            return e


def idle_line():
    note = state.get("note")
    if not state["tasks"]:
        return "idle · " + (note or "ready")
    line = f"idle · {state['tasks']} tasks done · context {state['ctx'] / 1000:.1f}k tokens"
    return line + (f" · {note}" if note else "")


def log_usage(n, started, ok):
    """Appends this task's tokens to .universe/agents/<name>.usage.jsonl."""
    path = cfg.get("session_file")
    if not path:
        return
    line = {"task": n, "ok": ok, "tokens": sum(state["calls"].values()), "calls": len(state["calls"]),
            "wall_s": round(time.time() - started, 1), "model": cfg.get("model")}
    with open(path.removesuffix(".json") + ".usage.jsonl", "a") as f:
        f.write(json.dumps(line) + "\n")


def task(prompt=None):
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("task needs a prompt")
    state["calls"] = {}
    ok = False
    state["tasks"] += 1
    n, started = state["tasks"], time.time()
    U.progress(f"busy · task {n}: {' '.join(prompt.split())[:80]}")
    try:
        send(prompt)
        # A leftover steer turn of the last task may answer first: skip it.
        expect = prompt if session.get("stray") else None
        while True:
            try:
                result = until_result(expect)
                expect = None
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
            ok = True
            return text
    finally:
        log_usage(n, started, ok)
        U.progress(idle_line())


session["id"] = saved_session_id()
start_session(resume=session["id"] is not None)
if session["resumed"]:
    try:
        session["proc"].wait(timeout=RESUME_CHECK_S)
    except subprocess.TimeoutExpired:
        pass
    if lost_resume():
        start_fresh()
    else:
        state["note"] = "resumed its earlier session"
U.progress(idle_line())
U.serve(cfg["service"], {"task": task}, describe="agent: " + " ".join(cfg["purpose"].split())[:120])
