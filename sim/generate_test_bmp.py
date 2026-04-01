#!/usr/bin/env python3
"""
Generate test BMP files for JPEG encoder testbench.
Creates 24-bit Windows BMP files (BITMAPINFOHEADER format).

Usage:
    python3 generate_test_bmp.py [output_dir]

Generates:
    - test_8x8_gradient.bmp     : 8x8 color gradient
    - test_16x16_gradient.bmp   : 16x16 color gradient
    - test_32x32_gradient.bmp   : 32x32 color gradient
    - test_64x64_gradient.bmp   : 64x64 color gradient
    - test_8x8_white.bmp        : 8x8 solid white
    - test_8x8_red.bmp          : 8x8 solid red
    - test_16x16_checker.bmp    : 16x16 checkerboard pattern
"""

import struct
import os
import sys


def create_bmp(width, height, pixels, filename):
    """
    Create a 24-bit BMP file.

    Args:
        width: Image width in pixels
        height: Image height in pixels
        pixels: List of (R, G, B) tuples, row-major, top-to-bottom order
        filename: Output file path
    """
    # Calculate row size with 4-byte padding
    row_data_size = width * 3
    row_padded_size = (row_data_size + 3) & ~3
    padding_bytes = row_padded_size - row_data_size

    # Pixel data size
    pixel_data_size = row_padded_size * height

    # File header (14 bytes) + Info header (40 bytes) = 54 bytes
    file_size = 54 + pixel_data_size
    data_offset = 54

    with open(filename, 'wb') as f:
        # BITMAPFILEHEADER (14 bytes)
        f.write(b'BM')                             # bfType: "BM"
        f.write(struct.pack('<I', file_size))       # bfSize
        f.write(struct.pack('<HH', 0, 0))           # bfReserved1, bfReserved2
        f.write(struct.pack('<I', data_offset))     # bfOffBits

        # BITMAPINFOHEADER (40 bytes)
        f.write(struct.pack('<I', 40))              # biSize
        f.write(struct.pack('<i', width))           # biWidth
        f.write(struct.pack('<i', height))          # biHeight (positive = bottom-up)
        f.write(struct.pack('<HH', 1, 24))          # biPlanes, biBitCount
        f.write(struct.pack('<I', 0))               # biCompression (BI_RGB)
        f.write(struct.pack('<I', pixel_data_size)) # biSizeImage
        f.write(struct.pack('<i', 2835))            # biXPelsPerMeter (72 DPI)
        f.write(struct.pack('<i', 2835))            # biYPelsPerMeter (72 DPI)
        f.write(struct.pack('<I', 0))               # biClrUsed
        f.write(struct.pack('<I', 0))               # biClrImportant

        # Pixel data (bottom-up order: last row first)
        padding = b'\x00' * padding_bytes
        for y in range(height - 1, -1, -1):
            for x in range(width):
                r, g, b = pixels[y * width + x]
                f.write(struct.pack('BBB', b, g, r))  # BMP stores as BGR
            f.write(padding)

    print(f"  Created: {filename} ({width}x{height}, {file_size} bytes)")


def generate_gradient(width, height):
    """Generate color gradient: R varies with x, G varies with y, B=128."""
    pixels = []
    for y in range(height):
        for x in range(width):
            r = int(x * 255 / max(width - 1, 1))
            g = int(y * 255 / max(height - 1, 1))
            b = 128
            pixels.append((r, g, b))
    return pixels


def generate_solid(width, height, r, g, b):
    """Generate solid color image."""
    return [(r, g, b)] * (width * height)


def generate_checker(width, height, block_size=4):
    """Generate checkerboard pattern."""
    pixels = []
    for y in range(height):
        for x in range(width):
            if ((x // block_size) + (y // block_size)) % 2 == 0:
                pixels.append((255, 255, 255))
            else:
                pixels.append((0, 0, 0))
    return pixels


def generate_rainbow_bars(width, height):
    """Generate vertical rainbow color bars."""
    colors = [
        (255, 0, 0),       # Red
        (255, 165, 0),     # Orange
        (255, 255, 0),     # Yellow
        (0, 255, 0),       # Green
        (0, 0, 255),       # Blue
        (75, 0, 130),      # Indigo
        (148, 0, 211),     # Violet
        (255, 255, 255),   # White
    ]
    pixels = []
    bar_width = max(width // len(colors), 1)
    for y in range(height):
        for x in range(width):
            idx = min(x // bar_width, len(colors) - 1)
            pixels.append(colors[idx])
    return pixels


def main():
    output_dir = sys.argv[1] if len(sys.argv) > 1 else "test_images"
    os.makedirs(output_dir, exist_ok=True)

    print("Generating test BMP files...")
    print(f"Output directory: {output_dir}")
    print()

    # Gradient images at various sizes
    for size in [8, 16, 32, 64]:
        pixels = generate_gradient(size, size)
        create_bmp(size, size, pixels,
                   os.path.join(output_dir, f"test_{size}x{size}_gradient.bmp"))

    # Solid color images (8x8)
    create_bmp(8, 8, generate_solid(8, 8, 255, 255, 255),
               os.path.join(output_dir, "test_8x8_white.bmp"))
    create_bmp(8, 8, generate_solid(8, 8, 255, 0, 0),
               os.path.join(output_dir, "test_8x8_red.bmp"))
    create_bmp(8, 8, generate_solid(8, 8, 0, 0, 0),
               os.path.join(output_dir, "test_8x8_black.bmp"))

    # Checkerboard (16x16)
    create_bmp(16, 16, generate_checker(16, 16, 4),
               os.path.join(output_dir, "test_16x16_checker.bmp"))

    # Rainbow bars (32x32)
    create_bmp(32, 32, generate_rainbow_bars(32, 32),
               os.path.join(output_dir, "test_32x32_rainbow.bmp"))

    # Non-square image (16x8)
    create_bmp(16, 8, generate_gradient(16, 8),
               os.path.join(output_dir, "test_16x8_gradient.bmp"))

    print()
    print(f"Done. Generated {10} test BMP files.")


if __name__ == "__main__":
    main()
