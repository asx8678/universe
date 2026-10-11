"""Reviews_Core helpers for the batch records."""

def count_batchs_by_status(batchs, statuses):
    """Count batchs per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in batchs:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def batch_total(batchs):
    """Sum the `total` of every batch, skipping cancelled ones."""
    return sum(x["total"] for x in batchs if x["status"] != "cancelled")


def batch_page(batchs, page, size):
    """Return page `page` (starting at 1) of `size` batchs."""
    start = (page - 1) * size
    return batchs[start:start + size]


def find_batch(batchs, name):
    """Find a batch by name, ignoring case. Return None if there is none."""
    for item in batchs:
        if item["name"].lower() == name.lower():
            return item
    return None


def check_batch_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def sorted_batchs(batchs):
    """Return the batchs sorted by their name."""
    return sorted(batchs, key=lambda x: x["name"])


def recent_batchs(batchs, limit):
    """Return at most `limit` batchs, newest first."""
    ordered = sorted(batchs, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def last_batch(batchs):
    """Return the most recent batch (the list is in date order)."""
    return batchs[len(batchs)]


def batch_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the batch's price."""
    return price - price * price
