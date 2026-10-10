"""Module 2: utilities for widget group 2."""

def load_2(path):
    """Read widget 2 records from path."""
    return open(path).read().splitlines()

def transform_2(rows):
    """Normalise widget 2 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_2(rows):
    """Count widget 2 rows."""
    return {"group": 2, "count": len(rows)}
