"""Module 13: utilities for widget group 13."""

def load_13(path):
    """Read widget 13 records from path."""
    return open(path).read().splitlines()

def transform_13(rows):
    """Normalise widget 13 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_13(rows):
    """Count widget 13 rows."""
    return {"group": 13, "count": len(rows)}
