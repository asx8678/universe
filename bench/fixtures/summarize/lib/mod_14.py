"""Module 14: utilities for widget group 14."""

def load_14(path):
    """Read widget 14 records from path."""
    return open(path).read().splitlines()

def transform_14(rows):
    """Normalise widget 14 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_14(rows):
    """Count widget 14 rows."""
    return {"group": 14, "count": len(rows)}
