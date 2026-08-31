"""Prueft, dass jedes in AmsApi.Bind.pas gebundene Symbol im Host existiert."""
import io, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from exports import exports

BIN = r"C:\Program Files (x86)\assfinet ams.5\BIN"
FILES = {'rtl': 'rtl230.bpl', 'vcl': 'vcl230.bpl',
         'afnUiCore.bpl': 'afnUiCore.bpl',
         'afnComponentsRt.bpl': 'afnComponentsRt.bpl',
         'afnBu.bpl': 'afnBu.bpl'}

src = io.open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           '..', 'src', 'AmsApi.Bind.pas'),
              encoding='utf-8').read()
# AmsSym(MOD_XXX, '...') - Modulkonstante und Symbolname
pairs = re.findall(r"AmsSym\(\s*(MOD_\w+)\s*,\s*\n?\s*'([^']+)'", src)
MODC = dict(re.findall(r"(MOD_\w+)\s*=\s*'([^']+)'", src))

cache = {}
bad = 0
for modc, sym in pairs:
    base = MODC[modc]
    fn = FILES[base]
    if fn not in cache:
        cache[fn] = set(exports(os.path.join(BIN, fn)))
    ok = sym in cache[fn]
    if not ok:
        bad += 1
    print('%-4s %-22s %s' % ('OK' if ok else 'FEHLT', fn, sym[:100]))
print()
print('%d Symbole geprueft, %d fehlen' % (len(pairs), bad))
sys.exit(1 if bad else 0)
