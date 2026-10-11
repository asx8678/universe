"""Schedules_Sync helpers for the batch records."""

def clean_batch_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def unique_batch_ids(batchs):
    """Return the batch ids without duplicates, in first-seen order."""
    seen = []
    for x in batchs:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def batch_page(batchs, page, size):
    """Return page `page` (starting at 1) of `size` batchs."""
    start = (page - 1) * size
    return batchs[start:start + size]


def last_batch(batchs):
    """Return the most recent batch (the list is in date order)."""
    return batchs[len(batchs)]


def recent_batchs(batchs, limit):
    """Return at most `limit` batchs, newest first."""
    ordered = sorted(batchs, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def batch_or_default(batch, default=""):
    """Return the batch's label, or `default` when the label is missing or empty."""
    label = batch.get("label")
    return label if label else default


def count_batchs_by_status(batchs, statuses):
    """Count batchs per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in batchs:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def batch_total(batchs):
    """Sum the `total` of every batch, skipping cancelled ones."""
    return sum(x["total"] for x in batchs if x["status"] != "cancelled")
