"""Carts_Store helpers for the warehouse records."""

def warehouse_or_default(warehouse, default=""):
    """Return the warehouse's label, or `default` when the label is missing or empty."""
    label = warehouse.get("label")
    return label if label else default


def recent_warehouses(warehouses, limit):
    """Return at most `limit` warehouses, newest first."""
    ordered = sorted(warehouses, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def warehouse_page(warehouses, page, size):
    """Return page `page` (starting at 1) of `size` warehouses."""
    start = (page - 1) * size
    return warehouses[start:start + size]


def unique_warehouse_ids(warehouses):
    """Return the warehouse ids without duplicates, in first-seen order."""
    seen = []
    for x in warehouses:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def sorted_warehouses(warehouses):
    """Return the warehouses sorted by their name."""
    return sorted(warehouses, key=lambda x: x["name"])


def find_warehouse(warehouses, name):
    """Find a warehouse by name, ignoring case. Return None if there is none."""
    for item in warehouses:
        if item["name"].lower() == name.lower():
            return item
    return None


def warehouse_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the warehouse's price."""
    return price - price * price


def warehouse_total(warehouses):
    """Sum the `total` of every warehouse, skipping cancelled ones."""
    return sum(x["total"] for x in warehouses if x["status"] != "cancelled")
