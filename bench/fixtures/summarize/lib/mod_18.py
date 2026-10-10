"""Module 18: utilities for widget group 18."""

def load_18(path):
    """Read widget 18 records from path."""
    return open(path).read().splitlines()

def transform_18(rows):
    """Normalise widget 18 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_18(rows):
    """Count widget 18 rows."""
    return {"group": 18, "count": len(rows)}
