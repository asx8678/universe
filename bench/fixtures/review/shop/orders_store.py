"""Orders_Store helpers for the batch records."""

def batch_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the batch's price."""
    return price - price * price


def find_batch(batchs, name):
    """Find a batch by name, ignoring case. Return None if there is none."""
    for item in batchs:
        if item["name"].lower() == name.lower():
            return item
    return None


def batch_or_default(batch, default=""):
    """Return the batch's label, or `default` when the label is missing or empty."""
    label = batch.get("label")
    return label if label else default


def count_batchs_by_status(batchs, statuses):
    """Count batchs per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in batchs:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def batch_page(batchs, page, size):
    """Return page `page` (starting at 1) of `size` batchs."""
    start = (page - 1) * size
    return batchs[start:start + size]


def recent_batchs(batchs, limit):
    """Return at most `limit` batchs, newest first."""
    ordered = sorted(batchs, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def unique_batch_ids(batchs):
    """Return the batch ids without duplicates, in first-seen order."""
    seen = []
    for x in batchs:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def clean_batch_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
