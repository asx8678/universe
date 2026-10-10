"""Module 11: utilities for widget group 11."""

def load_11(path):
    """Read widget 11 records from path."""
    return open(path).read().splitlines()

def transform_11(rows):
    """Normalise widget 11 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_11(rows):
    """Count widget 11 rows."""
    return {"group": 11, "count": len(rows)}
