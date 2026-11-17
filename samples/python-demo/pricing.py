"""Order pricing pipeline for the Stateglass demo shop.

The intentional bug lives in :func:`compute_order_total`: tax is calculated
from the pre-discount subtotal instead of the discounted subtotal.
"""

from __future__ import annotations

from catalog import TAX_RATE, product_for
from discounts import best_discount


def line_item(sku: str, quantity: int) -> dict:
    """Build one priced line item."""
    product = product_for(sku)
    unit_price = product["price"]
    line_total = unit_price * quantity
    return {
        "sku": sku,
        "name": product["name"],
        "qty": quantity,
        "unit_price": unit_price,
        "line_total": line_total,
    }


def compute_order_total(cart: list[tuple[str, int]], customer: str = "standard") -> dict:
    """Price a cart and return totals."""
    items: list[dict] = []
    subtotal = 0.0
    for sku, quantity in cart:
        item = line_item(sku, quantity)
        items.append(item)
        subtotal += item["line_total"]

    discount_rate = best_discount(subtotal, customer)
    discount_amount = round(subtotal * discount_rate, 2)
    discounted = subtotal - discount_amount

    # Intentional bug: should be ``discounted * TAX_RATE``.
    tax = round(subtotal * TAX_RATE, 2)
    total = round(discounted + tax, 2)

    return {
        "items": items,
        "subtotal": round(subtotal, 2),
        "discount_rate": discount_rate,
        "discount_amount": discount_amount,
        "discounted": round(discounted, 2),
        "tax_rate": TAX_RATE,
        "tax": tax,
        "total": total,
        "customer": customer,
    }
