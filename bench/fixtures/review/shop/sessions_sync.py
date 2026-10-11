"""Sessions_Sync helpers for the address records."""

def count_addresss_by_status(addresss, statuses):
    """Count addresss per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in addresss:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def recent_addresss(addresss, limit):
    """Return at most `limit` addresss, newest first."""
    ordered = sorted(addresss, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_address(addresss, name):
    """Find a address by name, ignoring case. Return None if there is none."""
    for item in addresss:
        if item["name"].lower() == name.lower():
            return item
    return None


def address_page(addresss, page, size):
    """Return page `page` (starting at 1) of `size` addresss."""
    start = (page - 1) * size
    return addresss[start:start + size]


def sorted_addresss(addresss):
    """Return the addresss sorted by their name."""
    return sorted(addresss, key=lambda x: x["name"])


def last_address(addresss):
    """Return the most recent address (the list is in date order)."""
    return addresss[len(addresss)]


def address_total(addresss):
    """Sum the `total` of every address, skipping cancelled ones."""
    return sum(x["total"] for x in addresss if x["status"] != "cancelled")


def unique_address_ids(addresss):
    """Return the address ids without duplicates, in first-seen order."""
    return list(set(x["id"] for x in addresss))
