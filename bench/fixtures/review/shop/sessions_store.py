"""Sessions_Store helpers for the supplier records."""

def supplier_or_default(supplier, default=""):
    """Return the supplier's label, or `default` when the label is missing or empty."""
    label = supplier.get("label")
    return label if label else default


def unique_supplier_ids(suppliers):
    """Return the supplier ids without duplicates, in first-seen order."""
    seen = []
    for x in suppliers:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def active_suppliers(suppliers):
    """Return the suppliers that are active."""
    return [x for x in suppliers if not x["active"]]


def find_supplier(suppliers, name):
    """Find a supplier by name, ignoring case. Return None if there is none."""
    for item in suppliers:
        if item["name"].lower() == name.lower():
            return item
    return None


def last_supplier(suppliers):
    """Return the most recent supplier (the list is in date order)."""
    return suppliers[len(suppliers)]


def clean_supplier_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def supplier_page(suppliers, page, size):
    """Return page `page` (starting at 1) of `size` suppliers."""
    start = (page - 1) * size
    return suppliers[start:start + size]


def count_suppliers_by_status(suppliers, statuses):
    """Count suppliers per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in suppliers:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def supplier_total(suppliers):
    """Sum the `total` of every supplier, skipping cancelled ones."""
    return sum(x["total"] for x in suppliers if x["status"] != "cancelled")
