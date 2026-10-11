"""Generate the steer acceptance fixture: a code review whose brief changes mid-way.

    python3 bench/gen_review.py

Writes bench/fixtures/review/ (a small Python package plus REVIEW_ORDER.md and
instructions.md) and the answer key bench/graders/review_answers.json.

The first brief asks for three kinds of logic bug a reviewer finds only by
reading each function (an inverted condition, a wrong variable, an
off-by-one), so the review takes minutes, longer than a tick's wait. The
mid-run message (bench/run.py MIDRUN["review"]) adds a fourth that needs
reading, not grep: a docstring that promises something the code doesn't do,
and says to skip web/ from then on. Docstring defects sit only in the second
half of the review order, so only a reviewer told mid-task can find them;
web/ files there carry defects too, which a reviewer told to skip them must
not report. Seeded: the same output every run.
"""

import json
import pathlib
import random

BENCH = pathlib.Path(__file__).resolve().parent
FIXTURE = BENCH / "fixtures" / "review"
ANSWERS = BENCH / "graders" / "review_answers.json"
SEED = 11

ENTITIES = ["order", "invoice", "customer", "shipment", "coupon", "ticket", "product", "refund",
            "payment", "cart", "review", "supplier", "warehouse", "report", "session", "address",
            "account", "message", "schedule", "batch"]

# Each template: (name, docstring, correct body, docstring-defect body). The
# defect body runs but breaks the docstring's promise. {e} is the entity.
TEMPLATES = [
    ("sorted_{e}s", "Return the {e}s sorted by their name.",
     "    return sorted({e}s, key=lambda x: x[\"name\"])",
     "    return list({e}s)"),
    ("check_{e}_amount", "Raise ValueError if the amount is negative; return it rounded to cents.",
     "    if amount < 0:\n        raise ValueError(\"negative amount\")\n    return round(amount, 2)",
     "    return round(amount, 2)"),
    ("find_{e}", "Find a {e} by name, ignoring case. Return None if there is none.",
     "    for item in {e}s:\n        if item[\"name\"].lower() == name.lower():\n            return item\n    return None",
     "    for item in {e}s:\n        if item[\"name\"] == name:\n            return item\n    return None"),
    ("recent_{e}s", "Return at most `limit` {e}s, newest first.",
     "    ordered = sorted({e}s, key=lambda x: x[\"created\"], reverse=True)\n    return ordered[:limit]",
     "    ordered = sorted({e}s, key=lambda x: x[\"created\"], reverse=True)\n    return ordered"),
    ("clean_{e}_lines", "Strip surrounding whitespace from each line and drop empty lines.",
     "    return [line.strip() for line in lines if line.strip()]",
     "    return [line for line in lines if line]"),
    ("{e}_total", "Sum the `total` of every {e}, skipping cancelled ones.",
     "    return sum(x[\"total\"] for x in {e}s if x[\"status\"] != \"cancelled\")",
     "    return sum(x[\"total\"] for x in {e}s)"),
    ("unique_{e}_ids", "Return the {e} ids without duplicates, in first-seen order.",
     "    seen = []\n    for x in {e}s:\n        if x[\"id\"] not in seen:\n            seen.append(x[\"id\"])\n    return seen",
     "    return list(set(x[\"id\"] for x in {e}s))"),
    ("{e}_or_default", "Return the {e}'s label, or `default` when the label is missing or empty.",
     "    label = {e}.get(\"label\")\n    return label if label else default",
     "    return {e}.get(\"label\", default)"),
    ("count_{e}s_by_status", "Count {e}s per status. Every status in `statuses` appears, with 0 if unused.",
     "    counts = {{s: 0 for s in statuses}}\n    for x in {e}s:\n        counts[x[\"status\"]] = counts.get(x[\"status\"], 0) + 1\n    return counts",
     "    counts = {{}}\n    for x in {e}s:\n        counts[x[\"status\"]] = counts.get(x[\"status\"], 0) + 1\n    return counts"),
    ("{e}_page", "Return page `page` (starting at 1) of `size` {e}s.",
     "    start = (page - 1) * size\n    return {e}s[start:start + size]",
     "    start = page * size\n    return {e}s[start:start + size]"),
]

ARGS = {
    "sorted_": "{e}s", "check_": "amount", "find_": "{e}s, name", "recent_": "{e}s, limit",
    "clean_": "lines", "unique_": "{e}s", "count_": "{e}s, statuses",
}

# Logic bugs of the first brief, as whole functions: visible only by reading
# the code (grep can't find them), so the reviewer reads every file.
X_KINDS = {
    "inverted-condition": ("active_{e}s", "Return the {e}s that are active.",
                           "{e}s", "    return [x for x in {e}s if not x[\"active\"]]"),
    "wrong-variable": ("{e}_discounted", "Apply the discount `rate` (0-1) to the {e}'s price.",
                       "price, rate", "    return price - price * price"),
    "off-by-one": ("last_{e}", "Return the most recent {e} (the list is in date order).",
                   "{e}s", "    return {e}s[len({e}s)]"),
}

def args_for(name, e):
    for prefix, a in ARGS.items():
        if name.startswith(prefix):
            return a.format(e=e)
    if name.endswith("_total"):
        return f"{e}s"
    if name.endswith("_or_default"):
        return f"{e}, default=\"\""
    if name.endswith("_page"):
        return f"{e}s, page, size"
    return f"{e}s"


def function(name, doc, args, body):
    return f"def {name}({args}):\n    \"\"\"{doc}\"\"\"\n{body}\n"


def main():
    r = random.Random(SEED)
    # 80 modules under shop/ and 20 under web/: one reviewer takes several
    # minutes, longer than a tick's 90 s wait, so a change can reach it mid-way.
    areas = ["orders", "invoices", "customers", "shipping", "coupons", "tickets", "catalog",
             "refunds", "payments", "carts", "reviews", "suppliers", "stock", "reports",
             "sessions", "addresses", "accounts", "messages", "schedules", "batches"]
    parts = ["core", "store", "rules", "sync"]
    core = [f"shop/{a}_{p}.py" for p in parts for a in areas]
    web = [f"web/{m}.py" for m in ["handlers", "forms", "views", "routes", "api", "auth", "uploads",
                                   "templates", "pages", "admin", "widgets", "feeds", "hooks",
                                   "search", "export", "import", "media", "static", "errors", "health"]]
    first, second = core[:40], core[40:]
    rest = second + web
    r.shuffle(rest)
    order = first + rest

    answers = {"order": order, "first_half": first, "x": [], "y": [], "web_y": [], "web_x": []}
    if FIXTURE.exists():
        for p in sorted(FIXTURE.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    for path in order:
        e = r.choice(ENTITIES)
        in_web = path.startswith("web/")
        in_second = path not in first
        funcs = []
        templates = r.sample(TEMPLATES, 7)
        # Docstring defects only where the changed brief applies: second half.
        n_y = r.choice([1, 1, 2]) if in_second else 0
        y_idx = set(r.sample(range(7), n_y))
        for i, (name, doc, good, bad) in enumerate(templates):
            fname = name.format(e=e)
            body = (bad if i in y_idx else good).format(e=e)
            funcs.append(function(fname, doc.format(e=e), args_for(name, e), body))
            if i in y_idx:
                answers["web_y" if in_web else "y"].append({"path": path, "function": fname})
        # One or two line-level bugs per file, and their clean twins elsewhere.
        for kind in r.sample(list(X_KINDS), r.choice([1, 2])):
            name, doc, args, body = X_KINDS[kind]
            fname = name.format(e=e)
            funcs.append(function(fname, doc.format(e=e), args.format(e=e), body.format(e=e)))
            answers["web_x" if in_web and in_second else "x"].append(
                {"path": path, "function": fname, "kind": kind})
        r.shuffle(funcs)
        header = f'"""{path.split("/")[-1][:-3].title()} helpers for the {e} records."""\n\n'
        target = FIXTURE / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(header + "\n\n".join(funcs))

    (FIXTURE / "shop" / "__init__.py").write_text("")
    (FIXTURE / "web" / "__init__.py").write_text("")
    (FIXTURE / "REVIEW_ORDER.md").write_text(
        "# Review order\n\nReview the files in exactly this order, one at a time:\n\n"
        + "\n".join(f"{i + 1}. {p}" for i, p in enumerate(order)) + "\n")
    (FIXTURE / "instructions.md").write_text(INSTRUCTIONS)
    ANSWERS.write_text(json.dumps(answers, indent=1) + "\n")
    print(f"{len(order)} files ({len(web)} under web/) · {len(answers['x']) + len(answers['web_x'])} "
          f"line-level bugs · {len(answers['y'])} docstring defects outside web/, "
          f"{len(answers['web_y'])} in web/")


INSTRUCTIONS = """# Code review

Review the Python package in this directory (`shop/` and `web/`) for bugs,
file by file in the order given in `REVIEW_ORDER.md`, reading each function.
Look for:

- `inverted-condition`: a condition that keeps or rejects the wrong items
- `wrong-variable`: an argument or variable used where another was meant
- `off-by-one`: an index or range that is one too far or one short

Write `review.md` with one line per finding:

    <path>::<function> | <kind> | <one-line explanation>

For example: `shop/orders_core.py::active_orders | inverted-condition | keeps the inactive orders`.
"""

if __name__ == "__main__":
    main()
