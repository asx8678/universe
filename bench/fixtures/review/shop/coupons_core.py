"""Coupons_Core helpers for the customer records."""

def count_customers_by_status(customers, statuses):
    """Count customers per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in customers:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def last_customer(customers):
    """Return the most recent customer (the list is in date order)."""
    return customers[len(customers)]


def check_customer_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def clean_customer_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def customer_page(customers, page, size):
    """Return page `page` (starting at 1) of `size` customers."""
    start = (page - 1) * size
    return customers[start:start + size]


def customer_total(customers):
    """Sum the `total` of every customer, skipping cancelled ones."""
    return sum(x["total"] for x in customers if x["status"] != "cancelled")


def sorted_customers(customers):
    """Return the customers sorted by their name."""
    return sorted(customers, key=lambda x: x["name"])


def customer_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the customer's price."""
    return price - price * price


def recent_customers(customers, limit):
    """Return at most `limit` customers, newest first."""
    ordered = sorted(customers, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
