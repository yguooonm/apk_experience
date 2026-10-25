#!/usr/bin/env python3
"""zipalign 等价实现：让 resources.arsc / *.so 的数据区起始偏移 %4==0。"""
import sys, struct, zlib, zipfile

ALIGN = 4
NEED = ('.arsc', '.so')
SL = '<IHHHHHIIIHH'
SC = '<IHHHHHHIIIHHHHHII'


def dos(dt):
    return ((dt[3] << 11) | (dt[4] << 5) | (dt[5] // 2),
            ((dt[0] - 1980) << 9) | (dt[1] << 5) | dt[2])


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(src) as z:
        items = [(i.filename, z.read(i.filename), i.date_time) for i in z.infolist()]

    buf = bytearray()
    central = []
    rep = []

    for name, data, dt in items:
        nb = name.encode()
        need = name.endswith(NEED)

        if need:
            comp, method = data, 0
        else:
            co = zlib.compressobj(6, zlib.DEFLATED, -15)
            comp = co.compress(data) + co.flush()
            method = 8
        crc = zlib.crc32(data) & 0xffffffff

        off = len(buf)
        base = off + 30 + len(nb)

        extra = b''
        if need and base % ALIGN:
            # extra = 4 字节头(ID+len) + (pad-4) 字节数据；总长 pad ∈ {4,5,6,7}
            # zip 解析按 len(extra) 读取，不要求是 4 的倍数
            rem = base % ALIGN
            pad = ALIGN - rem
            while pad < 4:
                pad += ALIGN
            assert 4 <= pad <= 7, f'pad 越界: {pad}'
            extra = struct.pack('<HH', 0xD935, pad - 4) + b'\x00' * (pad - 4)

        t, d = dos(dt)
        lh = struct.pack(SL, 0x04034B50, 20, 0, method, t, d, crc,
                         len(comp), len(data), len(nb), len(extra))
        ds = off + len(lh) + len(nb) + len(extra)
        assert (not need) or ds % ALIGN == 0, f'{name} 未对齐: {ds}'

        buf += lh + nb + extra + comp
        central.append(struct.pack(SC, 0x02014B50, 20, 20, 0, method, t, d, crc,
                                   len(comp), len(data), len(nb), len(extra),
                                   0, 0, 0, 0o100644 << 16, off) + nb + extra)
        rep.append((name, ds, need))

    cdb = b''.join(central)
    eocd = struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, len(items), len(items),
                       len(cdb), len(buf), 0)
    with open(dst, 'wb') as f:
        f.write(buf)
        f.write(cdb)
        f.write(eocd)

    ok = True
    print('  条目                                   数据偏移  对齐')
    for n, o, need in rep:
        if need:
            g = (o % ALIGN == 0)
            ok = ok and g
            print(f'  {n:38s} {o:<9d} {"OK" if g else "FAIL"}')
        else:
            print(f'  {n:38s} {o:<9d} -')
    print('对齐:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
