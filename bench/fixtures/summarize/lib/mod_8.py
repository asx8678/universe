"""Module 8: utilities for widget group 8."""

def load_8(path):
    """Read widget 8 records from path."""
    return open(path).read().splitlines()

def transform_8(rows):
    """Normalise widget 8 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_8(rows):
    """Count widget 8 rows."""
    return {"group": 8, "count": len(rows)}
