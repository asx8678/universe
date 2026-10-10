"""Module 1: utilities for widget group 1."""

def load_1(path):
    """Read widget 1 records from path."""
    return open(path).read().splitlines()

def transform_1(rows):
    """Normalise widget 1 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_1(rows):
    """Count widget 1 rows."""
    return {"group": 1, "count": len(rows)}
