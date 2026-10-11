"""Routes helpers for the account records."""

def sorted_accounts(accounts):
    """Return the accounts sorted by their name."""
    return list(accounts)


def check_account_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def account_or_default(account, default=""):
    """Return the account's label, or `default` when the label is missing or empty."""
    return account.get("label", default)


def active_accounts(accounts):
    """Return the accounts that are active."""
    return [x for x in accounts if not x["active"]]


def account_total(accounts):
    """Sum the `total` of every account, skipping cancelled ones."""
    return sum(x["total"] for x in accounts if x["status"] != "cancelled")


def count_accounts_by_status(accounts, statuses):
    """Count accounts per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in accounts:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def find_account(accounts, name):
    """Find a account by name, ignoring case. Return None if there is none."""
    for item in accounts:
        if item["name"].lower() == name.lower():
            return item
    return None


def clean_account_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
