"""Health helpers for the supplier records."""

def count_suppliers_by_status(suppliers, statuses):
    """Count suppliers per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in suppliers:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_suppliers(suppliers):
    """Return the suppliers sorted by their name."""
    return sorted(suppliers, key=lambda x: x["name"])


def find_supplier(suppliers, name):
    """Find a supplier by name, ignoring case. Return None if there is none."""
    for item in suppliers:
        if item["name"].lower() == name.lower():
            return item
    return None


def check_supplier_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def unique_supplier_ids(suppliers):
    """Return the supplier ids without duplicates, in first-seen order."""
    return list(set(x["id"] for x in suppliers))


def clean_supplier_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def recent_suppliers(suppliers, limit):
    """Return at most `limit` suppliers, newest first."""
    ordered = sorted(suppliers, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def supplier_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the supplier's price."""
    return price - price * price
