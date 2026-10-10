"""Module 16: utilities for widget group 16."""

def load_16(path):
    """Read widget 16 records from path."""
    return open(path).read().splitlines()

def transform_16(rows):
    """Normalise widget 16 rows."""
    return [r.strip().lower() for r in rows if r.strip()]

def summary_16(rows):
    """Count widget 16 rows."""
    return {"group": 16, "count": len(rows)}
