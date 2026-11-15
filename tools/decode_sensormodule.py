#!/usr/bin/env python3
"""Decode register-setting tables from a Qualcomm CamX sensormodule .bin
("QTI Chromatix Header" / Parameter Parser V5). Usage: decode_sensormodule.py FILE
Layout found by inspection: a pointer table of 16-byte entries
(id, offset, size, x) starting where entry 0 has id 0; offsets are relative to
the data segment. A register record is 14 little-endian u32:
addr, count, data-id, addrType, dataType, operation, 1, id+1, 0, id+2, 0, id+3, 0, id+4
with the value at data[id] and the delay (us) at data[id+1]."""
import struct, sys, json
d = open(sys.argv[1], 'rb').read()
def w(o, n=1): return struct.unpack_from('<%dI' % n, d, o)
# header: section table at 0x9c.. gives (offset,size,..) triples; data segment is the last
segs = w(0xb0, 10)
symoff, symsize, dataoff, datasize = segs[2], segs[3], segs[8], segs[9]
PT = symoff - 0x10
def ent(i): return w(PT + i * 16, 4)
def val(i):
    _, off, size, _ = ent(i)
    return w(dataoff + off)[0] if size >= 4 else None
recs = []
o = dataoff
while o < len(d) - 56:
    a = w(o, 14)
    if (a[1] == 1 and a[3] in (1, 2) and a[4] in (1, 2) and a[5] < 4 and a[6] == 1 and
            a[7] == a[2] + 1 and a[9] == a[2] + 2 and a[11] == a[2] + 3 and a[13] == a[2] + 4 and a[0] < 0x10000):
        recs.append((o, a)); o += 56
    else:
        o += 1
tables = []; prev = None
for o, a in recs:
    if prev is None or o != prev + 56: tables.append({'offset': o, 'regs': []})
    tables[-1]['regs'].append({'addr': a[0], 'val': val(a[2]), 'addr_bytes': a[3], 'data_bytes': a[4], 'op': a[5], 'delay_us': val(a[2] + 1)})
    prev = o
json.dump({'data_offset': dataoff, 'tables': tables}, sys.stdout, indent=0)
