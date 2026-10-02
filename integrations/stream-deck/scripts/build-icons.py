import pathlib
import struct
import zlib

root = pathlib.Path(__file__).resolve().parents[1] / 'com.joeblau.stream-studio.sdPlugin' / 'imgs'
root.mkdir(parents=True, exist_ok=True)

def png(size):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            u, v = x / size, y / size
            color = (24, 44, 59, 255)
            # Original geometric studio icon: a monitor and play pointer.
            monitor = .17 <= u <= .83 and .20 <= v <= .69
            border = monitor and (u < .20 or u > .80 or v < .23 or v > .66)
            stand = .46 <= u <= .54 and .69 <= v <= .80 or .31 <= u <= .69 and .79 <= v <= .83
            play = .43 <= u <= .65 and abs(v - .445) <= (u - .43) * .75
            if border or stand: color = (237, 244, 250, 255)
            if play: color = (107, 226, 178, 255)
            rows.extend(color)
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')

(root / 'plugin.png').write_bytes(png(256))
(root / 'plugin@2x.png').write_bytes(png(512))
for label, size in [('command', 20), ('command@2x', 40), ('category', 28), ('category@2x', 56)]:
    (root / f'{label}.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 28 28"><rect x="3" y="4" width="22" height="16" rx="2" fill="none" stroke="#fff" stroke-width="2"/><path d="M12 9L18 12L12 15Z M14 20V24 M9 24H19" fill="#fff" stroke="#fff" stroke-width="2"/></svg>')
for label, size in [('key',72),('key@2x',144)]:
    (root / f'{label}.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 144 144"><rect width="144" height="144" rx="16" fill="#182c3b"/><path d="M50 32L100 60L50 88Z" fill="#6be2b2"/></svg>')
