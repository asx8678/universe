"""Module 17: utilities for widget group 17."""

def load_17(path):
    """Read widget 17 records from path."""
    return open(path).read().splitlines()

def transform_17(rows):
    """Normalise widget 17 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_17(rows):
    """Count widget 17 rows."""
    return {"group": 17, "count": len(rows)}
