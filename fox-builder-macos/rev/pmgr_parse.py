#!/usr/bin/env python3
import base64, re, struct

path = '/home/yjlee/fox-builder/fox-builder-macos/rev/ioreg_armiodev.txt'
txt = open(path, encoding='utf-8', errors='replace').read()

def getblob(key, start=0):
    m = re.search(r'<key>' + key + r'</key>\s*<data>\s*([A-Za-z0-9+/=\s]+?)\s*</data>', txt[start:])
    if not m:
        return None
    return base64.b64decode(re.sub(r'\s', '', m.group(1)))

dev = getblob('devices')
ps = getblob('ps-regs')

# pmgr node "reg": extract within the pmgr node section (starts at name match)
pmgr_name_pos = txt.find('<string>pmgr</string>')
pmgr_reg = getblob('reg', pmgr_name_pos)
regs = []
for i in range(len(pmgr_reg)//16):
    addr, size = struct.unpack('<QQ', pmgr_reg[i*16:(i+1)*16])
    regs.append(addr)
print(f'pmgr reg regions: {[(hex(a)) for a in regs]}')

psu = struct.unpack(f'<{len(ps)//4}I', ps)
print('ps-regs triplets (idx: reg_idx, offset):')
for i in range(len(psu)//3):
    print(f'  [{i}] reg_idx={psu[3*i]} offset=0x{psu[3*i+1]:x}')

def psreg_base(idx):
    return regs[psu[3*idx]] + psu[3*idx+1]

N = len(dev)//48
recs = []
for i in range(N):
    r = dev[i*48:(i+1)*48]
    flags = r[0]
    id1 = r[3]
    p16 = struct.unpack('<HH', r[4:8])
    addr_offset = r[10]
    psreg_idx = r[11]
    id2 = struct.unpack('<H', r[26:28])[0]
    name = r[32:48].split(b'\0')[0].decode('ascii', 'replace')
    recs.append(dict(flags=flags, id1=id1, id2=id2, p16=p16,
                     addr_offset=addr_offset, psreg_idx=psreg_idx, name=name))

print(f'devices: {N} (id1[0]={recs[0]["id1"]:#x} id1[1]={recs[1]["id1"]:#x} -> u8id={recs[0]["id1"] != recs[1]["id1"]})')

def getid(r):
    return r['id2']  # u16 space (clock-gates values exceed 0xff)

def parents(r):
    return r['p16']

byid = {}
for r in recs:
    byid.setdefault(getid(r), r)

def addr(r):
    return psreg_base(r['psreg_idx']) + (r['addr_offset'] << 3)

def show(r, indent=0):
    virtual = bool(r['flags'] & 0x10)
    print('  '*indent + f"id={getid(r):#06x} {r['name']!r} addr=0x{addr(r):x} "
          f"psreg={r['psreg_idx']} off<<3=0x{r['addr_offset']<<3:x} flags=0x{r['flags']:02x}"
          + (' VIRTUAL' if virtual else ''))

print('\n== validation anchors (expect avd_sys@+0x410, fpwm1@+0x1e0, mmx@+0x358, dpa1@+0x2f0) ==')
for want, exp in (('AVD_SYS', 0x410), ('FPWM1', 0x1e0), ('MMX', 0x358), ('DPA1', 0x2f0)):
    r = next((x for x in recs if x['name'] == want), None)
    if r:
        a = addr(r) + 0x200000000
        ok = 'MATCH' if a == 0x23b700000 + exp else f'MISMATCH exp 0x{0x23b700000+exp:x}'
        print(f'  {want}: id={getid(r):#06x} addr=0x{a:x} {ok}')

print('\n== avd clock-gates 0x12b/0x12c/0x12d (leaf first, then parents) ==')
def walk(gid, depth=0, seen=None):
    if seen is None:
        seen = set()
    r = byid.get(gid)
    if not r:
        print('  '*depth + f'id={gid:#06x} NOT FOUND'); return
    show(r, depth)
    if gid in seen:
        return
    seen.add(gid)
    # m1n1 skips the ps write for VIRTUAL devices but STILL powers parents
    for p in parents(r):
        if p:
            walk(p, depth+1, seen)

for gid in (0x12b, 0x12c, 0x12d, 0x145):
    print(f'-- device {gid:#06x}:')
    walk(gid)

print('\n== avd/dart related devices ==')
for r in recs:
    if 'avd' in r['name'].lower() or 'dart' in r['name'].lower():
        show(r)

print('\n== psreg region usage histogram ==')
from collections import Counter
print(Counter(r['psreg_idx'] for r in recs))
