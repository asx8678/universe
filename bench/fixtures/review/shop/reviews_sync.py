"""Reviews_Sync helpers for the supplier records."""

def supplier_total(suppliers):
    """Sum the `total` of every supplier, skipping cancelled ones."""
    return sum(x["total"] for x in suppliers if x["status"] != "cancelled")


def supplier_page(suppliers, page, size):
    """Return page `page` (starting at 1) of `size` suppliers."""
    start = page * size
    return suppliers[start:start + size]


def find_supplier(suppliers, name):
    """Find a supplier by name, ignoring case. Return None if there is none."""
    for item in suppliers:
        if item["name"].lower() == name.lower():
            return item
    return None


def sorted_suppliers(suppliers):
    """Return the suppliers sorted by their name."""
    return sorted(suppliers, key=lambda x: x["name"])


def active_suppliers(suppliers):
    """Return the suppliers that are active."""
    return [x for x in suppliers if not x["active"]]


def clean_supplier_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def check_supplier_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def supplier_or_default(supplier, default=""):
    """Return the supplier's label, or `default` when the label is missing or empty."""
    label = supplier.get("label")
    return label if label else default
