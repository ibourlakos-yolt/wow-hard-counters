"""Draw the dash used for dashed borders (the Overview tab's Window-only cards, HC-73), made in code.

Writes, from the repo root:
  HardCounters/Media/Dash.tga   8x8, 32-bit RGBA, uncompressed: white where x < 5 and y < 5, clear elsewhere.
A horizontal edge samples the top rows (u repeats along the edge), a vertical edge the left columns (v repeats):
one file draws both. Run in WSL (no Pillow needed): python3 tools/draw-dash.py
"""
import os
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
N, ON = 8, 5

header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, N, N, 32, 0x28)   # top-left origin, 8 alpha bits
pixels = bytearray()
for y in range(N):
    for x in range(N):
        on = x < ON and y < ON
        pixels += bytes((255, 255, 255, 255 if on else 0))                       # BGRA
with open(os.path.join(ROOT, "HardCounters", "Media", "Dash.tga"), "wb") as f:
    f.write(header + bytes(pixels))
