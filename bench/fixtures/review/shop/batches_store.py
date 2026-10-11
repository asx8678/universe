"""Batches_Store helpers for the ticket records."""

def find_ticket(tickets, name):
    """Find a ticket by name, ignoring case. Return None if there is none."""
    for item in tickets:
        if item["name"].lower() == name.lower():
            return item
    return None


def last_ticket(tickets):
    """Return the most recent ticket (the list is in date order)."""
    return tickets[len(tickets)]


def unique_ticket_ids(tickets):
    """Return the ticket ids without duplicates, in first-seen order."""
    seen = []
    for x in tickets:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def ticket_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the ticket's price."""
    return price - price * price


def ticket_page(tickets, page, size):
    """Return page `page` (starting at 1) of `size` tickets."""
    start = (page - 1) * size
    return tickets[start:start + size]


def count_tickets_by_status(tickets, statuses):
    """Count tickets per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in tickets:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def check_ticket_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def recent_tickets(tickets, limit):
    """Return at most `limit` tickets, newest first."""
    ordered = sorted(tickets, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def ticket_total(tickets):
    """Sum the `total` of every ticket, skipping cancelled ones."""
    return sum(x["total"] for x in tickets if x["status"] != "cancelled")
