"""Reports_Core helpers for the supplier records."""

def sorted_suppliers(suppliers):
    """Return the suppliers sorted by their name."""
    return sorted(suppliers, key=lambda x: x["name"])


def check_supplier_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def supplier_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the supplier's price."""
    return price - price * price


def clean_supplier_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def unique_supplier_ids(suppliers):
    """Return the supplier ids without duplicates, in first-seen order."""
    seen = []
    for x in suppliers:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def count_suppliers_by_status(suppliers, statuses):
    """Count suppliers per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in suppliers:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def supplier_page(suppliers, page, size):
    """Return page `page` (starting at 1) of `size` suppliers."""
    start = (page - 1) * size
    return suppliers[start:start + size]


def active_suppliers(suppliers):
    """Return the suppliers that are active."""
    return [x for x in suppliers if not x["active"]]


def recent_suppliers(suppliers, limit):
    """Return at most `limit` suppliers, newest first."""
    ordered = sorted(suppliers, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
