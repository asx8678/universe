# Code review

Review the Python package in this directory (`shop/` and `web/`) for bugs,
file by file in the order given in `REVIEW_ORDER.md`, reading each function.
Look for:

- `inverted-condition`: a condition that keeps or rejects the wrong items
- `wrong-variable`: an argument or variable used where another was meant
- `off-by-one`: an index or range that is one too far or one short

Write `review.md` with one line per finding:

    <path>::<function> | <kind> | <one-line explanation>

For example: `shop/orders_core.py::active_orders | inverted-condition | keeps the inactive orders`.
