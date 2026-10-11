"""Addresses_Store helpers for the warehouse records."""

def warehouse_or_default(warehouse, default=""):
    """Return the warehouse's label, or `default` when the label is missing or empty."""
    label = warehouse.get("label")
    return label if label else default


def check_warehouse_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def sorted_warehouses(warehouses):
    """Return the warehouses sorted by their name."""
    return sorted(warehouses, key=lambda x: x["name"])


def active_warehouses(warehouses):
    """Return the warehouses that are active."""
    return [x for x in warehouses if not x["active"]]


def unique_warehouse_ids(warehouses):
    """Return the warehouse ids without duplicates, in first-seen order."""
    seen = []
    for x in warehouses:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def recent_warehouses(warehouses, limit):
    """Return at most `limit` warehouses, newest first."""
    ordered = sorted(warehouses, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def clean_warehouse_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def warehouse_total(warehouses):
    """Sum the `total` of every warehouse, skipping cancelled ones."""
    return sum(x["total"] for x in warehouses if x["status"] != "cancelled")


def last_warehouse(warehouses):
    """Return the most recent warehouse (the list is in date order)."""
    return warehouses[len(warehouses)]
