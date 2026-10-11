"""Messages_Sync helpers for the supplier records."""

def supplier_total(suppliers):
    """Sum the `total` of every supplier, skipping cancelled ones."""
    return sum(x["total"] for x in suppliers if x["status"] != "cancelled")


def supplier_page(suppliers, page, size):
    """Return page `page` (starting at 1) of `size` suppliers."""
    start = (page - 1) * size
    return suppliers[start:start + size]


def unique_supplier_ids(suppliers):
    """Return the supplier ids without duplicates, in first-seen order."""
    return list(set(x["id"] for x in suppliers))


def last_supplier(suppliers):
    """Return the most recent supplier (the list is in date order)."""
    return suppliers[len(suppliers)]


def clean_supplier_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line for line in lines if line]


def find_supplier(suppliers, name):
    """Find a supplier by name, ignoring case. Return None if there is none."""
    for item in suppliers:
        if item["name"].lower() == name.lower():
            return item
    return None


def supplier_or_default(supplier, default=""):
    """Return the supplier's label, or `default` when the label is missing or empty."""
    label = supplier.get("label")
    return label if label else default


def check_supplier_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)
