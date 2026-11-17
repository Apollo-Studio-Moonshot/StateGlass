# Stateglass demo project

A four-file Python pricing pipeline with one intentional bug.

**The bug:** `compute_order_total` in `pricing.py` computes tax from the
pre-discount subtotal instead of the discounted subtotal.

Try this in Stateglass:

1. Open this folder and run it with `Cmd/Ctrl+Enter`.
2. In the variable inspector, select `total`.
3. Step through its history — the tax branch computes `17.12` from `207.50`
   instead of computing it from the discounted subtotal of `196.88`.
4. Open the data-flow tab for `total` to see which lines feed it.
5. Create an experiment and change `tax = round(subtotal * TAX_RATE, 2)` to
   `tax = round(discounted * TAX_RATE, 2)`, then compare the two executions.

The program is deterministic and makes no network calls.
