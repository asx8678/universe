"""Module 12: utilities for widget group 12."""

def load_12(path):
    """Read widget 12 records from path."""
    return open(path).read().splitlines()

def transform_12(rows):
    """Normalise widget 12 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_12(rows):
    """Count widget 12 rows."""
    return {"group": 12, "count": len(rows)}
