"""Erzeugt ein einfaches 32x32-RGBA-PNG als Platzhalter-Symbol.

  python tools/mkicon.py <ziel.png> <r> <g> <b> [buchstabe]

Nur Standardbibliothek - kein Pillow noetig.
"""
import struct, sys, zlib

SIZE = 32
# 5x7-Pixelschrift, nur was gebraucht wird
FONT = {
    'H': ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    'W': ["#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #"],
    'A': ["  #  ", " # # ", "#   #", "#####", "#   #", "#   #", "#   #"],
    'R': ["#### ", "#   #", "#   #", "#### ", "#  # ", "#   #", "#   #"],
}


def png(path, rows):
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    hdr = struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0)  # 8 bit, RGBA
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', hdr))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def build(r, g, b, letter):
    rows = []
    cx = cy = (SIZE - 1) / 2.0
    glyph = FONT.get(letter.upper())
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            # runde Scheibe mit weichem Rand
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            a = 255 if d <= 14 else (0 if d >= 15.5 else int(255 * (15.5 - d) / 1.5))
            pr, pg, pb = r, g, b
            if glyph and a:
                gx, gy = x - (SIZE - 5) // 2, y - (SIZE - 7) // 2
                if 0 <= gx < 5 and 0 <= gy < 7 and glyph[gy][gx] == '#':
                    pr = pg = pb = 255
            row += [pr, pg, pb, a]
        rows.append(row)
    return rows


if __name__ == '__main__':
    dst = sys.argv[1]
    r, g, b = (int(v) for v in sys.argv[2:5])
    letter = sys.argv[5] if len(sys.argv) > 5 else ''
    png(dst, build(r, g, b, letter))
    print('geschrieben:', dst)
