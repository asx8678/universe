import re
import sqlite3
from datetime import date

MONTHS = {m: i + 1 for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july",
     "august", "september", "october", "november", "december"])}
TODAY = date(2026, 10, 1)


def _d(s):
    try:
        return date.fromisoformat(str(s)[:10])
    except Exception:
        return None


def _stem(w):
    return w[:-1] if w.endswith("s") and len(w) > 3 else w


def _words(s):
    return {_stem(w) for w in re.findall(r"[a-z]+", s.lower()) if len(w) > 2}


def _claim_date(body):
    low = body.lower()
    m = re.search(r"\b(?:(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?)?(" + "|".join(MONTHS) + r")\b", low)
    if not m:
        return None
    mon = MONTHS[m.group(2)]
    if m.group(1):
        day = int(m.group(1))
    else:
        pre = low[max(0, m.start() - 12):m.start()]
        if "early" in pre or "start" in pre or "beginning" in pre:
            day = 5
        elif "mid" in pre:
            day = 15
        elif "end" in pre or "late" in pre:
            day = 27
        else:
            day = 15
    try:
        return date(2026, mon, min(day, 28 if mon == 2 else 30))
    except Exception:
        return None


def _type(body):
    t = body.lower()
    if re.search(r"twice|two (separate |identical |same )?(payments?|charges?)|charged two|duplicate|double[- ]charged|two identical", t):
        return "duplicate"
    if re.search(r"never (came|arrived|showed|got|turned)|not received|never received|did not arrive|didn't arrive|no parcel|has not arrived|hasn't arrived|never appeared|not here|nothing here", t) and not re.search(r"wrong (item|thing|product)", t):
        return "not_received"
    if re.search(r"wrong (item|thing|product|one|pair|model|ones)|different (product|item|thing|model|pair|one)|not what i (ordered|picked|asked)|not the (product|item)|does not match|doesn't match|mix-?up|mixed up|other thing|other product|completely different", t):
        return "wrong_item"
    if re.search(r"faulty|broken|defect|flak|crack|leak|tear|peeling|flicker|stopped working|does not work|doesn't work|not work|rattl|damaged|fell apart|coming apart|soaked", t):
        return "defect"
    if re.search(r"late|delay|after the date|promised|missed|came much|many days", t):
        return "late"
    return "late"


def decide(db_path):
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    out = {}
    for c in con.execute("SELECT * FROM claims ORDER BY id").fetchall():
        body = c["body"] or ""
        cust = con.execute("SELECT * FROM customers WHERE id=?", (c["customer_id"],)).fetchone()
        orders = con.execute("SELECT * FROM orders WHERE customer_id=?", (c["customer_id"],)).fetchall()
        order = None
        for n in re.findall(r"#\s*(\d{4,})", body) + re.findall(r"\b(\d{6})\b", body):
            r = con.execute("SELECT * FROM orders WHERE id=?", (int(n),)).fetchone()
            if r:
                order = r
                break
        if order is None and orders:
            bw = _words(body)
            cd = _claim_date(body)
            best = None
            for o in orders:
                score = len(_words(o["product"] or "") & bw)
                od = _d(o["placed_at"])
                dist = abs((od - cd).days) if (od and cd) else 0
                key = (-score, dist)
                if best is None or key < best[0]:
                    best = (key, o)
            order = best[1]
        typ = _type(body)
        if order is None:
            out[c["id"]] = f"{c['id']}. escalate | {typ} | 0"
            continue
        oid = order["id"]
        if con.execute("SELECT 1 FROM refunds WHERE order_id=?", (oid,)).fetchone():
            dec = "escalate"
        else:
            s = con.execute("SELECT * FROM shipments WHERE order_id=?", (oid,)).fetchone()
            dec = "deny"
            if typ == "late":
                p, d = (_d(s["promised_date"]), _d(s["delivered_date"])) if s else (None, None)
                dec = "approve" if p and d and d > p else "deny"
            elif typ == "defect":
                d = _d(s["delivered_date"]) if s else None
                cl = _d(c["created_at"]) or TODAY
                dec = "approve" if d and (cl - d).days <= 30 else "deny"
            elif typ == "duplicate":
                n = con.execute("SELECT COUNT(*) FROM payments WHERE order_id=?", (oid,)).fetchone()[0]
                dec = "approve" if n >= 2 else "deny"
            elif typ == "wrong_item":
                dec = "approve" if s and (s["shipped_sku"] or "") != (order["sku"] or "") else "deny"
            elif typ == "not_received":
                if not s:
                    dec = "approve"
                else:
                    norm = lambda x: re.sub(r"\s+", " ", (x or "").strip().lower())
                    if (s["status"] or "").lower() != "delivered":
                        dec = "approve"
                    elif norm(s["delivered_address"]) != norm(cust["address"] if cust else ""):
                        dec = "approve"
                    else:
                        dec = "deny"
        out[c["id"]] = f"{c['id']}. {dec} | {typ} | {oid}"
    con.close()
    return {k: v for k, v in out.items()}
