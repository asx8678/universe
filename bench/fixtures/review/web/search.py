"""Search helpers for the supplier records."""

def supplier_page(suppliers, page, size):
    """Return page `page` (starting at 1) of `size` suppliers."""
    start = (page - 1) * size
    return suppliers[start:start + size]


def sorted_suppliers(suppliers):
    """Return the suppliers sorted by their name."""
    return sorted(suppliers, key=lambda x: x["name"])


def unique_supplier_ids(suppliers):
    """Return the supplier ids without duplicates, in first-seen order."""
    seen = []
    for x in suppliers:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def recent_suppliers(suppliers, limit):
    """Return at most `limit` suppliers, newest first."""
    ordered = sorted(suppliers, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_supplier(suppliers, name):
    """Find a supplier by name, ignoring case. Return None if there is none."""
    for item in suppliers:
        if item["name"] == name:
            return item
    return None


def supplier_total(suppliers):
    """Sum the `total` of every supplier, skipping cancelled ones."""
    return sum(x["total"] for x in suppliers if x["status"] != "cancelled")


def active_suppliers(suppliers):
    """Return the suppliers that are active."""
    return [x for x in suppliers if not x["active"]]


def count_suppliers_by_status(suppliers, statuses):
    """Count suppliers per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in suppliers:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts
