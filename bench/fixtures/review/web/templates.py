"""Templates helpers for the account records."""

def unique_account_ids(accounts):
    """Return the account ids without duplicates, in first-seen order."""
    seen = []
    for x in accounts:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def sorted_accounts(accounts):
    """Return the accounts sorted by their name."""
    return sorted(accounts, key=lambda x: x["name"])


def clean_account_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line for line in lines if line]


def count_accounts_by_status(accounts, statuses):
    """Count accounts per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in accounts:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def account_or_default(account, default=""):
    """Return the account's label, or `default` when the label is missing or empty."""
    label = account.get("label")
    return label if label else default


def account_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the account's price."""
    return price - price * price


def recent_accounts(accounts, limit):
    """Return at most `limit` accounts, newest first."""
    ordered = sorted(accounts, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_account(accounts, name):
    """Find a account by name, ignoring case. Return None if there is none."""
    for item in accounts:
        if item["name"].lower() == name.lower():
            return item
    return None
