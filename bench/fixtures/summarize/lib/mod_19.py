"""Module 19: utilities for widget group 19."""

def load_19(path):
    """Read widget 19 records from path."""
    return open(path).read().splitlines()

def transform_19(rows):
    """Normalise widget 19 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_19(rows):
    """Count widget 19 rows."""
    return {"group": 19, "count": len(rows)}
