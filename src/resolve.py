import struct, subprocess, re, sys

f = open('ap_arm64e','rb').read()
magic, cputype, cpusub, ftype, ncmds, sizecmds, flags, _ = struct.unpack_from('<IIIIIIII', f, 0)
off = 32
sections = {}
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', f, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = f[off+8:off+24].rstrip(b'\0').decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', f, off+24)
        nsects = struct.unpack_from('<I', f, off+64)[0]
        so = off + 72
        for _s in range(nsects):
            sn = f[so:so+16].rstrip(b'\0').decode()
            sg = f[so+16:so+32].rstrip(b'\0').decode()
            addr, size = struct.unpack_from('<QQ', f, so+32)
            foff = struct.unpack_from('<I', f, so+48)[0]
            sections[(sg, sn)] = (addr, size, foff)
            so += 80
    off += cmdsize

def read_cstr(vmaddr):
    for (sg, sn), (addr, size, foff) in sections.items():
        if sn in ('__cstring','__const','__oslogstring') and addr <= vmaddr < addr+size:
            start = foff + (vmaddr - addr)
            end = f.index(b'\0', start)
            return f[start:end].decode('utf-8','replace')
    return None

# map __cfstring vmaddr -> python str
cfmap = {}
if ('__DATA_CONST','__cfstring') in sections:
    addr, size, foff = sections[('__DATA_CONST','__cfstring')]
    for i in range(0, size, 32):
        ent = addr + i
        raw = struct.unpack_from('<Q', f, foff + i + 16)[0]
        for mask in (0xFFFFFFFFF, 0x7FFFFFFFF, 0xFFFFFFFF):
            cand = raw & mask
            s = read_cstr(cand)
            if s and s.isprintable() and len(s) > 2:
                cfmap[ent] = s
                break

dis = subprocess.run(['otool','-arch','arm64e','-tV','ap_arm64e'],
                     capture_output=True, text=True).stdout.splitlines()

adrp_re = re.compile(r'^([0-9a-f]+)\s+adrp\s+(x\d+), (-?\d+)')
add_re  = re.compile(r'^([0-9a-f]+)\s+add\s+(x\d+), (x\d+), #(0x[0-9a-f]+|\d+)')
mov_re  = re.compile(r'^([0-9a-f]+)\s+mov\s+(w\d+), #(0x[0-9a-f]+|\d+)')
bl_re   = re.compile(r'^([0-9a-f]+)\s+bl\s+.*symbol stub for: (\S+)')

regs = {}
results = []
for line in dis:
    line = line.strip()
    m = adrp_re.match(line)
    if m:
        pc = int(m.group(1), 16); page = int(m.group(3))
        regs[m.group(2)] = (pc & ~0xfff) + page * 4096
        continue
    m = add_re.match(line)
    if m:
        src = m.group(3); imm = int(m.group(4), 0)
        if src in regs:
            regs[m.group(2)] = regs[src] + imm
        continue
    m = mov_re.match(line)
    if m:
        regs[m.group(2)] = int(m.group(3), 0)
        continue
    m = bl_re.match(line)
    if m:
        sym = m.group(2)
        if 'FigGetCFPreference' in sym or 'APSSettingsGet' in sym:
            def rs(r):
                v = regs.get(r)
                if v is None: return '?'
                return cfmap.get(v) or read_cstr(v) or hex(v)
            results.append((m.group(1), sym, rs('x0'), rs('x1'), regs.get('w2', '?')))
        regs.clear()

print(f"cfstrings resolved: {len(cfmap)}\n")
seen = set()
for pc, sym, a0, a1, a2 in results:
    key = (sym, a0, a1, str(a2))
    if key in seen: continue
    seen.add(key)
    print(f"{pc}  {sym.lstrip('_')}")
    print(f"     key    = {a0}")
    print(f"     domain = {a1}")
    print(f"     default= {a2}\n")
