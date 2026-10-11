"""Suppliers_Sync helpers for the report records."""

def report_or_default(report, default=""):
    """Return the report's label, or `default` when the label is missing or empty."""
    label = report.get("label")
    return label if label else default


def unique_report_ids(reports):
    """Return the report ids without duplicates, in first-seen order."""
    seen = []
    for x in reports:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def report_page(reports, page, size):
    """Return page `page` (starting at 1) of `size` reports."""
    start = (page - 1) * size
    return reports[start:start + size]


def last_report(reports):
    """Return the most recent report (the list is in date order)."""
    return reports[len(reports)]


def count_reports_by_status(reports, statuses):
    """Count reports per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in reports:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def report_total(reports):
    """Sum the `total` of every report, skipping cancelled ones."""
    return sum(x["total"] for x in reports)


def find_report(reports, name):
    """Find a report by name, ignoring case. Return None if there is none."""
    for item in reports:
        if item["name"].lower() == name.lower():
            return item
    return None


def sorted_reports(reports):
    """Return the reports sorted by their name."""
    return sorted(reports, key=lambda x: x["name"])
