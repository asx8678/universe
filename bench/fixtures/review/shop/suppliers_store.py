"""Suppliers_Store helpers for the schedule records."""

def unique_schedule_ids(schedules):
    """Return the schedule ids without duplicates, in first-seen order."""
    seen = []
    for x in schedules:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def check_schedule_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def recent_schedules(schedules, limit):
    """Return at most `limit` schedules, newest first."""
    ordered = sorted(schedules, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def count_schedules_by_status(schedules, statuses):
    """Count schedules per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in schedules:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def schedule_or_default(schedule, default=""):
    """Return the schedule's label, or `default` when the label is missing or empty."""
    label = schedule.get("label")
    return label if label else default


def clean_schedule_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def schedule_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the schedule's price."""
    return price - price * price


def find_schedule(schedules, name):
    """Find a schedule by name, ignoring case. Return None if there is none."""
    for item in schedules:
        if item["name"].lower() == name.lower():
            return item
    return None
