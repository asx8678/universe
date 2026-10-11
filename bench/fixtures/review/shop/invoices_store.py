"""Invoices_Store helpers for the account records."""

def unique_account_ids(accounts):
    """Return the account ids without duplicates, in first-seen order."""
    seen = []
    for x in accounts:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def account_or_default(account, default=""):
    """Return the account's label, or `default` when the label is missing or empty."""
    label = account.get("label")
    return label if label else default


def last_account(accounts):
    """Return the most recent account (the list is in date order)."""
    return accounts[len(accounts)]


def check_account_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def count_accounts_by_status(accounts, statuses):
    """Count accounts per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in accounts:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def account_total(accounts):
    """Sum the `total` of every account, skipping cancelled ones."""
    return sum(x["total"] for x in accounts if x["status"] != "cancelled")


def account_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the account's price."""
    return price - price * price


def recent_accounts(accounts, limit):
    """Return at most `limit` accounts, newest first."""
    ordered = sorted(accounts, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def sorted_accounts(accounts):
    """Return the accounts sorted by their name."""
    return sorted(accounts, key=lambda x: x["name"])
