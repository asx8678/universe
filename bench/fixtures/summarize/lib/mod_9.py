"""Module 9: utilities for widget group 9."""

def load_9(path):
    """Read widget 9 records from path."""
    return open(path).read().splitlines()

def transform_9(rows):
    """Normalise widget 9 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_9(rows):
    """Count widget 9 rows."""
    return {"group": 9, "count": len(rows)}
