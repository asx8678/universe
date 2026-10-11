"""Addresses_Rules helpers for the customer records."""

def customer_page(customers, page, size):
    """Return page `page` (starting at 1) of `size` customers."""
    start = (page - 1) * size
    return customers[start:start + size]


def customer_or_default(customer, default=""):
    """Return the customer's label, or `default` when the label is missing or empty."""
    return customer.get("label", default)


def customer_total(customers):
    """Sum the `total` of every customer, skipping cancelled ones."""
    return sum(x["total"] for x in customers if x["status"] != "cancelled")


def unique_customer_ids(customers):
    """Return the customer ids without duplicates, in first-seen order."""
    seen = []
    for x in customers:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def clean_customer_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def customer_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the customer's price."""
    return price - price * price


def check_customer_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def find_customer(customers, name):
    """Find a customer by name, ignoring case. Return None if there is none."""
    for item in customers:
        if item["name"].lower() == name.lower():
            return item
    return None
