"""Accounts_Store helpers for the invoice records."""

def invoice_page(invoices, page, size):
    """Return page `page` (starting at 1) of `size` invoices."""
    start = (page - 1) * size
    return invoices[start:start + size]


def active_invoices(invoices):
    """Return the invoices that are active."""
    return [x for x in invoices if not x["active"]]


def invoice_or_default(invoice, default=""):
    """Return the invoice's label, or `default` when the label is missing or empty."""
    label = invoice.get("label")
    return label if label else default


def check_invoice_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def find_invoice(invoices, name):
    """Find a invoice by name, ignoring case. Return None if there is none."""
    for item in invoices:
        if item["name"].lower() == name.lower():
            return item
    return None


def unique_invoice_ids(invoices):
    """Return the invoice ids without duplicates, in first-seen order."""
    seen = []
    for x in invoices:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def sorted_invoices(invoices):
    """Return the invoices sorted by their name."""
    return sorted(invoices, key=lambda x: x["name"])


def count_invoices_by_status(invoices, statuses):
    """Count invoices per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in invoices:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts
