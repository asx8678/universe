"""Module 3: utilities for widget group 3."""

def load_3(path):
    """Read widget 3 records from path."""
    return open(path).read().splitlines()

def transform_3(rows):
    """Normalise widget 3 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_3(rows):
    """Count widget 3 rows."""
    return {"group": 3, "count": len(rows)}
