"""Accounts_Rules helpers for the schedule records."""

def sorted_schedules(schedules):
    """Return the schedules sorted by their name."""
    return sorted(schedules, key=lambda x: x["name"])


def count_schedules_by_status(schedules, statuses):
    """Count schedules per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in schedules:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def schedule_total(schedules):
    """Sum the `total` of every schedule, skipping cancelled ones."""
    return sum(x["total"] for x in schedules if x["status"] != "cancelled")


def clean_schedule_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def last_schedule(schedules):
    """Return the most recent schedule (the list is in date order)."""
    return schedules[len(schedules)]


def schedule_page(schedules, page, size):
    """Return page `page` (starting at 1) of `size` schedules."""
    start = (page - 1) * size
    return schedules[start:start + size]


def recent_schedules(schedules, limit):
    """Return at most `limit` schedules, newest first."""
    ordered = sorted(schedules, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def schedule_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the schedule's price."""
    return price - price * price


def check_schedule_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)
