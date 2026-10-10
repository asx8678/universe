"""Module 6: utilities for widget group 6."""

def load_6(path):
    """Read widget 6 records from path."""
    return open(path).read().splitlines()

def transform_6(rows):
    """Normalise widget 6 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_6(rows):
    """Count widget 6 rows."""
    return {"group": 6, "count": len(rows)}
