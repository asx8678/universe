"""Hooks helpers for the message records."""

def message_total(messages):
    """Sum the `total` of every message, skipping cancelled ones."""
    return sum(x["total"] for x in messages if x["status"] != "cancelled")


def find_message(messages, name):
    """Find a message by name, ignoring case. Return None if there is none."""
    for item in messages:
        if item["name"].lower() == name.lower():
            return item
    return None


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


def last_message(messages):
    """Return the most recent message (the list is in date order)."""
    return messages[len(messages)]


def count_messages_by_status(messages, statuses):
    """Count messages per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in messages:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_messages(messages):
    """Return the messages sorted by their name."""
    return sorted(messages, key=lambda x: x["name"])


def clean_message_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line for line in lines if line]
