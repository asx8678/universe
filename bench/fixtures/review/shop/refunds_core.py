"""Refunds_Core helpers for the report records."""

def active_reports(reports):
    """Return the reports that are active."""
    return [x for x in reports if not x["active"]]


def report_or_default(report, default=""):
    """Return the report's label, or `default` when the label is missing or empty."""
    label = report.get("label")
    return label if label else default


def check_report_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def clean_report_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_reports(reports):
    """Return the reports sorted by their name."""
    return sorted(reports, key=lambda x: x["name"])


def report_page(reports, page, size):
    """Return page `page` (starting at 1) of `size` reports."""
    start = (page - 1) * size
    return reports[start:start + size]


def recent_reports(reports, limit):
    """Return at most `limit` reports, newest first."""
    ordered = sorted(reports, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_report(reports, name):
    """Find a report by name, ignoring case. Return None if there is none."""
    for item in reports:
        if item["name"].lower() == name.lower():
            return item
    return None
