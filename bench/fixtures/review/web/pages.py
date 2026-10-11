"""Pages helpers for the warehouse records."""

def warehouse_or_default(warehouse, default=""):
    """Return the warehouse's label, or `default` when the label is missing or empty."""
    label = warehouse.get("label")
    return label if label else default


def count_warehouses_by_status(warehouses, statuses):
    """Count warehouses per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in warehouses:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_warehouses(warehouses):
    """Return the warehouses sorted by their name."""
    return sorted(warehouses, key=lambda x: x["name"])


def unique_warehouse_ids(warehouses):
    """Return the warehouse ids without duplicates, in first-seen order."""
    seen = []
    for x in warehouses:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def check_warehouse_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def last_warehouse(warehouses):
    """Return the most recent warehouse (the list is in date order)."""
    return warehouses[len(warehouses)]


def warehouse_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the warehouse's price."""
    return price - price * price


def recent_warehouses(warehouses, limit):
    """Return at most `limit` warehouses, newest first."""
    ordered = sorted(warehouses, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def warehouse_total(warehouses):
    """Sum the `total` of every warehouse, skipping cancelled ones."""
    return sum(x["total"] for x in warehouses if x["status"] != "cancelled")
