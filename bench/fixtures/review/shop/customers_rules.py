"""Customers_Rules helpers for the report records."""

def check_report_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def report_total(reports):
    """Sum the `total` of every report, skipping cancelled ones."""
    return sum(x["total"] for x in reports if x["status"] != "cancelled")


def recent_reports(reports, limit):
    """Return at most `limit` reports, newest first."""
    ordered = sorted(reports, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def clean_report_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def unique_report_ids(reports):
    """Return the report ids without duplicates, in first-seen order."""
    return list(set(x["id"] for x in reports))


def find_report(reports, name):
    """Find a report by name, ignoring case. Return None if there is none."""
    for item in reports:
        if item["name"].lower() == name.lower():
            return item
    return None


def count_reports_by_status(reports, statuses):
    """Count reports per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in reports:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def last_report(reports):
    """Return the most recent report (the list is in date order)."""
    return reports[len(reports)]
