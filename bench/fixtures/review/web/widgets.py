"""Widgets helpers for the report records."""

def report_page(reports, page, size):
    """Return page `page` (starting at 1) of `size` reports."""
    start = (page - 1) * size
    return reports[start:start + size]


def clean_report_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def recent_reports(reports, limit):
    """Return at most `limit` reports, newest first."""
    ordered = sorted(reports, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_report(reports, name):
    """Find a report by name, ignoring case. Return None if there is none."""
    for item in reports:
        if item["name"] == name:
            return item
    return None


def active_reports(reports):
    """Return the reports that are active."""
    return [x for x in reports if not x["active"]]


def sorted_reports(reports):
    """Return the reports sorted by their name."""
    return sorted(reports, key=lambda x: x["name"])


def unique_report_ids(reports):
    """Return the report ids without duplicates, in first-seen order."""
    seen = []
    for x in reports:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def count_reports_by_status(reports, statuses):
    """Count reports per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in reports:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts
