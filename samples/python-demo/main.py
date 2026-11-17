"""Stateglass demo project — a tiny order-pricing pipeline.

There is an intentional bug in this sample. Run it, select ``total`` in the
variable inspector, and follow its history to find where the value goes wrong.

Expected output for the default cart:

    Monitor Stand       2 x  $ 45.00 = $  90.00
    Mechanical Keyboard 1 x  $ 89.00 = $  89.00
    USB-C Cable         3 x  $  9.50 = $  28.50
    Subtotal                             $ 207.50
    Discount (gold, 5%)                 -$  10.38
    Tax (8.25%)                         +$  17.12
    Total                                $ 214.24

The bug: tax is computed from the pre-discount subtotal, so the total is
slightly too high.
"""

from __future__ import annotations

import sys

from catalog import format_money
from pricing import compute_order_total

DEFAULT_CART = [
    ("monitor-stand", 2),
    ("keyboard", 1),
    ("usb-cable", 3),
]


def parse_cart(argv: list[str]) -> list[tuple[str, int]]:
    """Parse ``sku:qty`` arguments, falling back to the demo cart."""
    if not argv:
        return list(DEFAULT_CART)
    cart: list[tuple[str, int]] = []
    for raw in argv:
        if ":" not in raw:
            raise SystemExit(f"invalid cart item {raw!r}; expected sku:qty")
        sku, qty_text = raw.split(":", 1)
        quantity = int(qty_text)
        if quantity <= 0:
            raise SystemExit(f"quantity for {sku} must be positive")
        cart.append((sku, quantity))
    return cart


def main(argv: list[str]) -> int:
    cart = parse_cart(argv)
    customer = "gold"
    order = compute_order_total(cart, customer)
    for item in order["items"]:
        name = item["name"]
        print(
            f"{name:<20}{item['qty']:>2} x {format_money(item['unit_price'])}"
            f" = {format_money(item['line_total']):>9}"
        )
    print("-" * 48)
    print(f"{'Subtotal':<32}{format_money(order['subtotal']):>12}")
    print(f"{'Discount (' + customer + ', ' + str(round(order['discount_rate'] * 100)) + '%)':<32}"
          f"{format_money(-order['discount_amount']):>12}")
    print(f"{'Tax (' + str(round(order['tax_rate'] * 100, 2)) + '%)':<32}"
          f"{format_money(order['tax']):>12}")
    print(f"{'Total':<32}{format_money(order['total']):>12}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
