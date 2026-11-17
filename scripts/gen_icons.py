#!/usr/bin/env python3
"""Generate Stateglass app icons without external image libraries."""
import math
import os
import struct
import zlib

BG = (10, 12, 16)
PANEL = (18, 23, 31)
BORDER = (44, 55, 72)
ACCENT = (86, 146, 255)
ACCENT_SOFT = (126, 176, 255)
DOT = (233, 240, 252)

S = 4  # supersampling factor


def rounded_rect(x, y, w, h, r, px, py):
    cx = min(max(px, x + r), x + w - r)
    cy = min(max(py, y + r), y + h - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r


def render(size):
    pixels = [[(0, 0, 0, 0) for _ in range(size)] for _ in range(size)]
    scale = S
    pts = [(0.24, 0.66), (0.38, 0.50), (0.52, 0.58), (0.62, 0.34), (0.78, 0.42)]
    for y in range(size):
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(scale):
                for sx in range(scale):
                    ux = (x + (sx + 0.5) / scale) / size
                    uy = (y + (sy + 0.5) / scale) / size
                    color = (0, 0, 0, 0)
                    if rounded_rect(0.03, 0.03, 0.94, 0.94, 0.22, ux, uy):
                        color = (*BG, 255)
                        inside = rounded_rect(0.14, 0.16, 0.72, 0.68, 0.10, ux, uy)
                        border = rounded_rect(0.135, 0.155, 0.73, 0.69, 0.105, ux, uy)
                        if inside:
                            color = (*PANEL, 255)
                        elif border:
                            color = (*BORDER, 255)
                        for i in range(len(pts) - 1):
                            ax, ay = pts[i]
                            bx, by = pts[i + 1]
                            vx, vy = bx - ax, by - ay
                            wx, wy = ux - ax, uy - ay
                            t = max(0.0, min(1.0, (wx * vx + wy * vy) / (vx * vx + vy * vy)))
                            dx, dy = ux - (ax + t * vx), uy - (ay + t * vy)
                            if dx * dx + dy * dy <= (0.011) ** 2:
                                color = (*ACCENT, 255)
                        for cx, cy in pts:
                            d = math.hypot(ux - cx, uy - cy)
                            if d <= 0.034:
                                color = (*DOT, 255)
                            elif d <= 0.048:
                                color = (*ACCENT_SOFT, 255)
                        if 0.22 <= ux <= 0.78 and abs(uy - 0.76) <= 0.006:
                            color = (*BORDER, 255)
                    acc[0] += color[0]
                    acc[1] += color[1]
                    acc[2] += color[2]
                    acc[3] += color[3]
            total = scale * scale
            pixels[y][x] = tuple(int(round(value / total)) for value in acc)
    return pixels


def write_png(path, pixels):
    size = len(pixels)
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *pixels[y][x]) for x in range(size))
        for y in range(size)
    )

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(
            ">I", zlib.crc32(tag + data) & 0xFFFFFFFF
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    out = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "src-tauri", "icons")
    )
    os.makedirs(out, exist_ok=True)
    iconset = os.path.join(out, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)

    sizes = {16, 32, 64, 128, 256, 512, 1024}
    rendered = {size: render(size) for size in sizes}

    write_png(os.path.join(out, "32x32.png"), rendered[32])
    write_png(os.path.join(out, "128x128.png"), rendered[128])
    write_png(os.path.join(out, "128x128@2x.png"), rendered[256])
    write_png(os.path.join(out, "icon.png"), rendered[1024])

    mapping = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in mapping.items():
        write_png(os.path.join(iconset, name), rendered[size])

    payloads = []
    for size in (256, 128, 64, 32, 16):
        path = os.path.join(out, f".tmp-{size}.png")
        write_png(path, rendered[size])
        with open(path, "rb") as handle:
            payloads.append((size, handle.read()))
        os.remove(path)

    header = struct.pack("<HHH", 0, 1, len(payloads))
    offset = 6 + 16 * len(payloads)
    entries = b""
    data = b""
    for size, payload in payloads:
        entries += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,
            size if size < 256 else 0,
            0,
            0,
            1,
            32,
            len(payload),
            offset,
        )
        data += payload
        offset += len(payload)
    with open(os.path.join(out, "icon.ico"), "wb") as handle:
        handle.write(header + entries + data)
    print("icons written to", out)


if __name__ == "__main__":
    main()
