"""Refunds_Store helpers for the ticket records."""

def recent_tickets(tickets, limit):
    """Return at most `limit` tickets, newest first."""
    ordered = sorted(tickets, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def clean_ticket_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def check_ticket_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def sorted_tickets(tickets):
    """Return the tickets sorted by their name."""
    return sorted(tickets, key=lambda x: x["name"])


def ticket_total(tickets):
    """Sum the `total` of every ticket, skipping cancelled ones."""
    return sum(x["total"] for x in tickets if x["status"] != "cancelled")


def ticket_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the ticket's price."""
    return price - price * price


def count_tickets_by_status(tickets, statuses):
    """Count tickets per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in tickets:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def ticket_or_default(ticket, default=""):
    """Return the ticket's label, or `default` when the label is missing or empty."""
    label = ticket.get("label")
    return label if label else default
