"""Module 5: utilities for widget group 5."""

def load_5(path):
    """Read widget 5 records from path."""
    return open(path).read().splitlines()

def transform_5(rows):
    """Normalise widget 5 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_5(rows):
    """Count widget 5 rows."""
    return {"group": 5, "count": len(rows)}
