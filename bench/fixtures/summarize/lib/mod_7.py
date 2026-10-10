"""Module 7: utilities for widget group 7."""

def load_7(path):
    """Read widget 7 records from path."""
    return open(path).read().splitlines()

def transform_7(rows):
    """Normalise widget 7 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_7(rows):
    """Count widget 7 rows."""
    return {"group": 7, "count": len(rows)}
