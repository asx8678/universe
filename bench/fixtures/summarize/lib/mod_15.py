"""Module 15: utilities for widget group 15."""

def load_15(path):
    """Read widget 15 records from path."""
    return open(path).read().splitlines()

def transform_15(rows):
    """Normalise widget 15 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_15(rows):
    """Count widget 15 rows."""
    return {"group": 15, "count": len(rows)}
