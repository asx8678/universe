"""Customers_Store helpers for the account records."""

def recent_accounts(accounts, limit):
    """Return at most `limit` accounts, newest first."""
    ordered = sorted(accounts, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def account_or_default(account, default=""):
    """Return the account's label, or `default` when the label is missing or empty."""
    label = account.get("label")
    return label if label else default


def find_account(accounts, name):
    """Find a account by name, ignoring case. Return None if there is none."""
    for item in accounts:
        if item["name"].lower() == name.lower():
            return item
    return None


def clean_account_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_accounts(accounts):
    """Return the accounts sorted by their name."""
    return sorted(accounts, key=lambda x: x["name"])


def check_account_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def last_account(accounts):
    """Return the most recent account (the list is in date order)."""
    return accounts[len(accounts)]


def account_total(accounts):
    """Sum the `total` of every account, skipping cancelled ones."""
    return sum(x["total"] for x in accounts if x["status"] != "cancelled")
