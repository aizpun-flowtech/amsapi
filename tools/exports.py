"""Exportnamen aus einer PE-Datei (BPL/DLL) listen.

Eigener Parser: pefile schneidet bei sehr grossen Exporttabellen ab
(afnBu.bpl hat ~34800 Symbole).

  python tools/exports.py <datei> [teilstring ...]
"""
import struct, sys


def exports(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3C)[0]
    assert d[pe:pe+4] == b'PE\0\0', 'kein PE'
    nsec, = struct.unpack_from('<H', d, pe + 6)
    optsz, = struct.unpack_from('<H', d, pe + 20)
    magic, = struct.unpack_from('<H', d, pe + 24)
    ddir = pe + 24 + (96 if magic == 0x10b else 112)
    edir_rva, edir_sz = struct.unpack_from('<II', d, ddir)
    secs = []
    off = pe + 24 + optsz
    for i in range(nsec):
        s = d[off + 40*i: off + 40*(i+1)]
        vsz, va, rsz, ra = struct.unpack_from('<IIII', s, 8)
        secs.append((va, max(vsz, rsz), ra))

    def r2o(rva):
        for va, sz, ra in secs:
            if va <= rva < va + sz:
                return ra + (rva - va)
        return None

    if not edir_rva:
        return []
    e = r2o(edir_rva)
    nnames, = struct.unpack_from('<I', d, e + 24)
    names_rva, = struct.unpack_from('<I', d, e + 32)
    nt = r2o(names_rva)
    out = []
    for i in range(nnames):
        p = r2o(struct.unpack_from('<I', d, nt + 4*i)[0])
        if p is None:
            continue
        z = d.index(b'\0', p)
        out.append(d[p:z].decode('latin1'))
    return out


if __name__ == '__main__':
    names = exports(sys.argv[1])
    pats = sys.argv[2:]
    if not pats:
        print(len(names), 'Exporte')
        for n in names[:50]:
            print(' ', n)
    else:
        for pat in pats:
            hits = [n for n in names if pat in n]
            print('%-40s %d Treffer' % (pat, len(hits)))
            for h in hits[:12]:
                print('   ', h)
