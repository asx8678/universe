"""Sessions_Core helpers for the review records."""

def count_reviews_by_status(reviews, statuses):
    """Count reviews per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in reviews:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def review_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the review's price."""
    return price - price * price


def review_or_default(review, default=""):
    """Return the review's label, or `default` when the label is missing or empty."""
    label = review.get("label")
    return label if label else default


def active_reviews(reviews):
    """Return the reviews that are active."""
    return [x for x in reviews if not x["active"]]


def check_review_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def sorted_reviews(reviews):
    """Return the reviews sorted by their name."""
    return sorted(reviews, key=lambda x: x["name"])


def unique_review_ids(reviews):
    """Return the review ids without duplicates, in first-seen order."""
    seen = []
    for x in reviews:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def find_review(reviews, name):
    """Find a review by name, ignoring case. Return None if there is none."""
    for item in reviews:
        if item["name"].lower() == name.lower():
            return item
    return None


def clean_review_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
