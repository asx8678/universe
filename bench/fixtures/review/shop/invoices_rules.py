"""Invoices_Rules helpers for the ticket records."""

def clean_ticket_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_tickets(tickets):
    """Return the tickets sorted by their name."""
    return sorted(tickets, key=lambda x: x["name"])


def count_tickets_by_status(tickets, statuses):
    """Count tickets per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in tickets:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def find_ticket(tickets, name):
    """Find a ticket by name, ignoring case. Return None if there is none."""
    for item in tickets:
        if item["name"] == name:
            return item
    return None


def unique_ticket_ids(tickets):
    """Return the ticket ids without duplicates, in first-seen order."""
    seen = []
    for x in tickets:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def active_tickets(tickets):
    """Return the tickets that are active."""
    return [x for x in tickets if not x["active"]]


def ticket_or_default(ticket, default=""):
    """Return the ticket's label, or `default` when the label is missing or empty."""
    label = ticket.get("label")
    return label if label else default


def recent_tickets(tickets, limit):
    """Return at most `limit` tickets, newest first."""
    ordered = sorted(tickets, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
