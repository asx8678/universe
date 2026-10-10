"""Module 20: utilities for widget group 20."""

def load_20(path):
    """Read widget 20 records from path."""
    return open(path).read().splitlines()

def transform_20(rows):
    """Normalise widget 20 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_20(rows):
    """Count widget 20 rows."""
    return {"group": 20, "count": len(rows)}
