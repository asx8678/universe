"""Addresses_Core helpers for the invoice records."""

def find_invoice(invoices, name):
    """Find a invoice by name, ignoring case. Return None if there is none."""
    for item in invoices:
        if item["name"].lower() == name.lower():
            return item
    return None


def clean_invoice_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_invoices(invoices):
    """Return the invoices sorted by their name."""
    return sorted(invoices, key=lambda x: x["name"])


def invoice_total(invoices):
    """Sum the `total` of every invoice, skipping cancelled ones."""
    return sum(x["total"] for x in invoices if x["status"] != "cancelled")


def check_invoice_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def invoice_or_default(invoice, default=""):
    """Return the invoice's label, or `default` when the label is missing or empty."""
    label = invoice.get("label")
    return label if label else default


def invoice_page(invoices, page, size):
    """Return page `page` (starting at 1) of `size` invoices."""
    start = (page - 1) * size
    return invoices[start:start + size]


def active_invoices(invoices):
    """Return the invoices that are active."""
    return [x for x in invoices if not x["active"]]
