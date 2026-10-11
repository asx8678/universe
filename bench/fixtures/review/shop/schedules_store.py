"""Schedules_Store helpers for the refund records."""

def unique_refund_ids(refunds):
    """Return the refund ids without duplicates, in first-seen order."""
    seen = []
    for x in refunds:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def refund_total(refunds):
    """Sum the `total` of every refund, skipping cancelled ones."""
    return sum(x["total"] for x in refunds if x["status"] != "cancelled")


def clean_refund_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def count_refunds_by_status(refunds, statuses):
    """Count refunds per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in refunds:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_refunds(refunds):
    """Return the refunds sorted by their name."""
    return sorted(refunds, key=lambda x: x["name"])


def refund_page(refunds, page, size):
    """Return page `page` (starting at 1) of `size` refunds."""
    start = (page - 1) * size
    return refunds[start:start + size]


def refund_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the refund's price."""
    return price - price * price


def last_refund(refunds):
    """Return the most recent refund (the list is in date order)."""
    return refunds[len(refunds)]


def recent_refunds(refunds, limit):
    """Return at most `limit` refunds, newest first."""
    ordered = sorted(refunds, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
