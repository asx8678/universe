"""Shipping_Store helpers for the review records."""

def count_reviews_by_status(reviews, statuses):
    """Count reviews per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in reviews:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def last_review(reviews):
    """Return the most recent review (the list is in date order)."""
    return reviews[len(reviews)]


def review_or_default(review, default=""):
    """Return the review's label, or `default` when the label is missing or empty."""
    label = review.get("label")
    return label if label else default


def recent_reviews(reviews, limit):
    """Return at most `limit` reviews, newest first."""
    ordered = sorted(reviews, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def clean_review_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_reviews(reviews):
    """Return the reviews sorted by their name."""
    return sorted(reviews, key=lambda x: x["name"])


def review_total(reviews):
    """Sum the `total` of every review, skipping cancelled ones."""
    return sum(x["total"] for x in reviews if x["status"] != "cancelled")


def unique_review_ids(reviews):
    """Return the review ids without duplicates, in first-seen order."""
    seen = []
    for x in reviews:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def active_reviews(reviews):
    """Return the reviews that are active."""
    return [x for x in reviews if not x["active"]]
