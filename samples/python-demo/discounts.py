"""Customer discount tiers for the Stateglass demo shop."""

from __future__ import annotations

DISCOUNT_TIERS = {
    "standard": 0.0,
    "silver": 0.02,
    "gold": 0.05,
    "platinum": 0.08,
}

VOLUME_THRESHOLD = 500.0
VOLUME_BONUS = 0.01


def best_discount(subtotal: float, customer: str) -> float:
    """Return the best applicable discount rate for a customer."""
    base = DISCOUNT_TIERS.get(customer, 0.0)
    rate = base
    if subtotal >= VOLUME_THRESHOLD:
        rate += VOLUME_BONUS
    return min(rate, 0.25)
