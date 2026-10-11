"""Catalog_Rules helpers for the customer records."""

def last_customer(customers):
    """Return the most recent customer (the list is in date order)."""
    return customers[len(customers)]


def unique_customer_ids(customers):
    """Return the customer ids without duplicates, in first-seen order."""
    seen = []
    for x in customers:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def sorted_customers(customers):
    """Return the customers sorted by their name."""
    return sorted(customers, key=lambda x: x["name"])


def customer_or_default(customer, default=""):
    """Return the customer's label, or `default` when the label is missing or empty."""
    label = customer.get("label")
    return label if label else default


def clean_customer_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def check_customer_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def customer_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the customer's price."""
    return price - price * price


def customer_page(customers, page, size):
    """Return page `page` (starting at 1) of `size` customers."""
    start = page * size
    return customers[start:start + size]


def recent_customers(customers, limit):
    """Return at most `limit` customers, newest first."""
    ordered = sorted(customers, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
