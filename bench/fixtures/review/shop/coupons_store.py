"""Coupons_Store helpers for the message records."""

def check_message_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def unique_message_ids(messages):
    """Return the message ids without duplicates, in first-seen order."""
    seen = []
    for x in messages:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def recent_messages(messages, limit):
    """Return at most `limit` messages, newest first."""
    ordered = sorted(messages, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def last_message(messages):
    """Return the most recent message (the list is in date order)."""
    return messages[len(messages)]


def clean_message_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def message_page(messages, page, size):
    """Return page `page` (starting at 1) of `size` messages."""
    start = (page - 1) * size
    return messages[start:start + size]


def count_messages_by_status(messages, statuses):
    """Count messages per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in messages:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def message_total(messages):
    """Sum the `total` of every message, skipping cancelled ones."""
    return sum(x["total"] for x in messages if x["status"] != "cancelled")
