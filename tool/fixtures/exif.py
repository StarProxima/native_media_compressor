"""Writes photo_exif_full.jpg: photo_exif_rotated.jpg with a full EXIF block
(camera, capture time, GPS at the Greenwich meridian and orientation 6) for
the metadata tests.

usage: python3 exif.py <fixtures dir>
"""
import struct
import sys

ASCII, SHORT, LONG, RATIONAL = 2, 3, 4, 5
SIZES = {ASCII: 1, SHORT: 2, LONG: 4, RATIONAL: 8}


def ifd(entries, start, next_ifd=0):
    """Little-endian IFD at offset [start]; values that do not fit in four
    bytes go right after it."""
    head = struct.pack("<H", len(entries))
    data_offset = start + 2 + 12 * len(entries) + 4
    body, data = b"", b""
    for tag, kind, value in sorted(entries, key=lambda e: e[0]):
        if kind == ASCII:
            raw, count = value.encode() + b"\0", len(value) + 1
        elif kind == SHORT:
            raw, count = struct.pack("<H", value), 1
        elif kind == LONG:
            raw, count = struct.pack("<I", value), 1
        else:
            raw = b"".join(struct.pack("<II", n, d) for n, d in value)
            count = len(value)
        if len(raw) <= 4:
            body += struct.pack("<HHI", tag, kind, count) + raw.ljust(4, b"\0")
        else:
            body += struct.pack("<HHII", tag, kind, count, data_offset + len(data))
            data += raw + (b"\0" if len(raw) % 2 else b"")
    return head + body + struct.pack("<I", next_ifd) + data


def tiff():
    # Offsets are from the start of the TIFF header; IFD0 starts at 8.
    gps = [
        (0x0001, ASCII, "N"),
        (0x0002, RATIONAL, [(51, 1), (28, 1), (4040, 100)]),
        (0x0003, ASCII, "W"),
        (0x0004, RATIONAL, [(0, 1), (0, 1), (540, 100)]),
    ]
    exif = [(0x9003, ASCII, "2026:11:10 12:34:56")]
    ifd0_entries = lambda exif_at, gps_at: [
        (0x010F, ASCII, "NMCTestCamera"),
        (0x0110, ASCII, "Model 1"),
        (0x0112, SHORT, 6),
        (0x8769, LONG, exif_at),
        (0x8825, LONG, gps_at),
    ]
    ifd0_len = len(ifd(ifd0_entries(0, 0), 8))
    exif_at = 8 + ifd0_len
    exif_block = ifd(exif, exif_at)
    gps_at = exif_at + len(exif_block)
    ifd0 = ifd(ifd0_entries(exif_at, gps_at), 8)
    return b"II*\0" + struct.pack("<I", 8) + ifd0 + exif_block + ifd(gps, gps_at)


def main(directory):
    src = open(f"{directory}/photo_exif_rotated.jpg", "rb").read()
    assert src[:2] == b"\xff\xd8"
    # Drop the existing APP1 segments and put ours right after SOI.
    pos, kept = 2, b""
    while src[pos] == 0xFF and src[pos + 1] in range(0xE0, 0xF0):
        length = struct.unpack(">H", src[pos + 2 : pos + 4])[0]
        if src[pos + 1] != 0xE1:
            kept += src[pos : pos + 2 + length]
        pos += 2 + length
    payload = b"Exif\0\0" + tiff()
    app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
    open(f"{directory}/photo_exif_full.jpg", "wb").write(
        src[:2] + app1 + kept + src[pos:]
    )


main(sys.argv[1])
