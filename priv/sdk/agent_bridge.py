"""Agent bridge: one headless `claude` session served as a Universe service.

Run by an agent worker (`serve` with an `agent` block). Starts

    claude -p --input-format stream-json --output-format stream-json --restricted ...

with the agent's purpose as its system prompt, then serves one function,
`task(prompt)`: the prompt goes in as a user message, the session's final
message comes back as the call's result. Calls arrive one at a time, so the
session is one conversation that remembers earlier tasks.

A reply starting with ``QUESTION:`` becomes ``U.ask``: the orchestrating
model sees the worker as asking, answers with a `reply` directive, and the
answer goes back into the session.

Config comes from the JSON file in ``UNIVERSE_AGENT_CONFIG``.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

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


state = {"tasks": 0, "ctx": 0, "crashes": []}
session = {}


def start_session():
    proc = subprocess.Popen(command(), cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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
    session.update(proc=proc, events=events)


def send(text):
    # A session that died (crash, killed) is replaced by a fresh one, which
    # has lost the conversation; more than 3 deaths in 60 s ends the agent.
    if session["proc"].poll() is not None:
        now = time.time()
        state["crashes"] = [t for t in state["crashes"] if now - t < 60] + [now]
        if len(state["crashes"]) > 3:
            print("claude session died 4 times in 60s; giving up", file=sys.stderr, flush=True)
            threading.Timer(0.5, os._exit, [3]).start()
            raise RuntimeError("claude session keeps dying; the agent stops")
        start_session()
        state["restarted"] = True
    msg = {"type": "user", "message": {"role": "user", "content": text}}
    session["proc"].stdin.write(json.dumps(msg) + "\n")
    session["proc"].stdin.flush()


def until_result():
    while True:
        e = session["events"].get()
        if e is None:
            code = session["proc"].wait()
            raise RuntimeError(f"claude session ended (exit {code}); the next task starts a fresh one")
        if e.get("type") == "assistant" and not e.get("parent_tool_use_id"):
            u = e.get("message", {}).get("usage") or {}
            ctx = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + \
                u.get("cache_creation_input_tokens", 0)
            if ctx:
                state["ctx"] = ctx
        elif e.get("type") == "result":
            return e


def idle_line():
    if not state["tasks"]:
        return "idle · ready"
    line = f"idle · {state['tasks']} tasks done · context {state['ctx'] / 1000:.1f}k tokens"
    return line + (" · session restarted" if state.get("restarted") else "")


def task(prompt=None):
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("task needs a prompt")
    state["tasks"] += 1
    n, started = state["tasks"], time.time()
    U.progress(f"busy · task {n}: {' '.join(prompt.split())[:80]}")
    try:
        send(prompt)
        while True:
            result = until_result()
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


start_session()
U.progress(idle_line())
U.serve(cfg["service"], {"task": task}, describe="agent: " + " ".join(cfg["purpose"].split())[:120])
