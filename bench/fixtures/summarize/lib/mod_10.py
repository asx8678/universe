"""Module 10: utilities for widget group 10."""

def load_10(path):
    """Read widget 10 records from path."""
    return open(path).read().splitlines()

def transform_10(rows):
    """Normalise widget 10 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_10(rows):
    """Count widget 10 rows."""
    return {"group": 10, "count": len(rows)}
