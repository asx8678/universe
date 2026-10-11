"""Reports_Store helpers for the message records."""

def message_page(messages, page, size):
    """Return page `page` (starting at 1) of `size` messages."""
    start = (page - 1) * size
    return messages[start:start + size]


def sorted_messages(messages):
    """Return the messages sorted by their name."""
    return sorted(messages, key=lambda x: x["name"])


def message_total(messages):
    """Sum the `total` of every message, skipping cancelled ones."""
    return sum(x["total"] for x in messages if x["status"] != "cancelled")


def active_messages(messages):
    """Return the messages that are active."""
    return [x for x in messages if not x["active"]]


def recent_messages(messages, limit):
    """Return at most `limit` messages, newest first."""
    ordered = sorted(messages, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def unique_message_ids(messages):
    """Return the message ids without duplicates, in first-seen order."""
    seen = []
    for x in messages:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def check_message_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def last_message(messages):
    """Return the most recent message (the list is in date order)."""
    return messages[len(messages)]


def message_or_default(message, default=""):
    """Return the message's label, or `default` when the label is missing or empty."""
    label = message.get("label")
    return label if label else default
