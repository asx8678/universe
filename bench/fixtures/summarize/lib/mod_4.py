"""Module 4: utilities for widget group 4."""

def load_4(path):
    """Read widget 4 records from path."""
    return open(path).read().splitlines()

def transform_4(rows):
    """Normalise widget 4 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_4(rows):
    """Count widget 4 rows."""
    return {"group": 4, "count": len(rows)}
