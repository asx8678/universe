"""Reviews_Store helpers for the product records."""

def find_product(products, name):
    """Find a product by name, ignoring case. Return None if there is none."""
    for item in products:
        if item["name"].lower() == name.lower():
            return item
    return None


def active_products(products):
    """Return the products that are active."""
    return [x for x in products if not x["active"]]


def last_product(products):
    """Return the most recent product (the list is in date order)."""
    return products[len(products)]


def check_product_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def clean_product_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def product_total(products):
    """Sum the `total` of every product, skipping cancelled ones."""
    return sum(x["total"] for x in products if x["status"] != "cancelled")


def sorted_products(products):
    """Return the products sorted by their name."""
    return sorted(products, key=lambda x: x["name"])


def recent_products(products, limit):
    """Return at most `limit` products, newest first."""
    ordered = sorted(products, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def product_page(products, page, size):
    """Return page `page` (starting at 1) of `size` products."""
    start = (page - 1) * size
    return products[start:start + size]
