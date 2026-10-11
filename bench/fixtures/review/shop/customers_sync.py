"""Customers_Sync helpers for the shipment records."""

def shipment_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the shipment's price."""
    return price - price * price


def unique_shipment_ids(shipments):
    """Return the shipment ids without duplicates, in first-seen order."""
    seen = []
    for x in shipments:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def shipment_total(shipments):
    """Sum the `total` of every shipment, skipping cancelled ones."""
    return sum(x["total"] for x in shipments if x["status"] != "cancelled")


def shipment_page(shipments, page, size):
    """Return page `page` (starting at 1) of `size` shipments."""
    start = page * size
    return shipments[start:start + size]


def sorted_shipments(shipments):
    """Return the shipments sorted by their name."""
    return sorted(shipments, key=lambda x: x["name"])


def recent_shipments(shipments, limit):
    """Return at most `limit` shipments, newest first."""
    ordered = sorted(shipments, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def check_shipment_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def shipment_or_default(shipment, default=""):
    """Return the shipment's label, or `default` when the label is missing or empty."""
    label = shipment.get("label")
    return label if label else default
