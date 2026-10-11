"""Payments_Rules helpers for the account records."""

def last_account(accounts):
    """Return the most recent account (the list is in date order)."""
    return accounts[len(accounts)]


def clean_account_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def account_or_default(account, default=""):
    """Return the account's label, or `default` when the label is missing or empty."""
    return account.get("label", default)


def recent_accounts(accounts, limit):
    """Return at most `limit` accounts, newest first."""
    ordered = sorted(accounts, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def sorted_accounts(accounts):
    """Return the accounts sorted by their name."""
    return sorted(accounts, key=lambda x: x["name"])


def active_accounts(accounts):
    """Return the accounts that are active."""
    return [x for x in accounts if not x["active"]]


def find_account(accounts, name):
    """Find a account by name, ignoring case. Return None if there is none."""
    for item in accounts:
        if item["name"].lower() == name.lower():
            return item
    return None


def count_accounts_by_status(accounts, statuses):
    """Count accounts per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in accounts:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def account_page(accounts, page, size):
    """Return page `page` (starting at 1) of `size` accounts."""
    start = (page - 1) * size
    return accounts[start:start + size]
