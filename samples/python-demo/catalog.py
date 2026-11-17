"""Product catalog for the Stateglass demo shop."""

from __future__ import annotations

TAX_RATE = 0.0825

CATALOG = {
    "monitor-stand": {
        "name": "Monitor Stand",
        "price": 45.00,
        "stock": 12,
    },
    "keyboard": {
        "name": "Mechanical Keyboard",
        "price": 89.00,
        "stock": 4,
    },
    "usb-cable": {
        "name": "USB-C Cable",
        "price": 9.50,
        "stock": 60,
    },
    "webcam": {
        "name": "4K Webcam",
        "price": 129.00,
        "stock": 0,
    },
}


def format_money(value: float) -> str:
    """Render a currency amount without locale-dependent formatting."""
    sign = "-" if value < 0 else ""
    cents = int(round(abs(value) * 100))
    dollars, remainder = divmod(cents, 100)
    grouped = f"{dollars:,}"
    return f"{sign}${grouped}.{remainder:02d}"


def product_for(sku: str) -> dict:
    """Look up a product, raising a readable error when it is unknown."""
    if sku not in CATALOG:
        raise KeyError(f"unknown sku: {sku}")
    return CATALOG[sku]
