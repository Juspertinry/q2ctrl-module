import struct
import sys
d=open(sys.argv[1] if len(sys.argv)>1 else "libsyncboss_2entry.so","rb").read()
ok=True
def chk(c,msg):
    global ok
    print(("  OK  " if c else " FAIL ")+msg); ok=ok and c

# header
e_phoff,=struct.unpack_from("<Q",d,0x20); e_phnum,=struct.unpack_from("<H",d,0x38)
e_phentsize,=struct.unpack_from("<H",d,0x36)
chk(e_phoff==0x40000 and e_phnum==8,"e_phoff=0x%x e_phnum=%d"%(e_phoff,e_phnum))

# parse phdrs
loads=[]; dynoff=None
for i in range(e_phnum):
    o=e_phoff+i*e_phentsize
    pt,fl=struct.unpack_from("<II",d,o)
    poff,pva,ppa,pfsz,pmsz,pal=struct.unpack_from("<QQQQQQ",d,o+8)
    if pt==1: loads.append((poff,pva,pfsz,pmsz,fl,pal))
    if pt==2: dynoff=poff
newseg=[l for l in loads if l[1]==0x40000]
chk(len(newseg)==1,"new PT_LOAD present")
s=newseg[0]
chk(s[4]==6,"new seg flags=rw(%d)"%s[4])
chk((s[1]-s[0])%0x10000==0,"congruence (va-off)%%align==0")
chk(s[0]+s[2]<=len(d),"new seg file range within file (end 0x%x, file 0x%x)"%(s[0]+s[2],len(d)))
chk(s[3]==s[2],"filesz==memsz")

def va2off(va):
    for off,v,fsz,msz,fl,al in loads:
        if v<=va<v+fsz: return off+(va-v)
    return None
def inrw(va):
    for off,v,fsz,msz,fl,al in loads:
        if v<=va<v+msz and fl&2: return True
    return False

# dynamic
DT={}
o=dynoff
while True:
    tag,val=struct.unpack_from("<qQ",d,o); DT[tag]=val
    if tag==0: break
    o+=16
RELA=DT[7]; RELASZ=DT[8]; RELACOUNT=DT[0x6ffffff9]
chk(RELA==0x401c0,"DT_RELA=0x%x"%RELA)
chk(RELASZ==0x840,"DT_RELASZ=0x%x (%d entries)"%(RELASZ,RELASZ//24))
chk(RELACOUNT==87,"DT_RELACOUNT=%d"%RELACOUNT)

rela_off=va2off(RELA)
chk(rela_off is not None,"reloc table VA maps to file (off=0x%x)"%(rela_off or -1))

# parse relocs, simulate with fake bias
BIAS=0x7000000000
mem={}
tblptr=None; new_rel_seen=0
rels=[]
for i in range(RELASZ//24):
    r_off,r_info,r_add=struct.unpack_from("<QQq",d,rela_off+i*24)
    rels.append((r_off,r_info,r_add))
    t=r_info&0xffffffff
    if t==0x403:  # RELATIVE
        chk_addr=r_off
        mem[r_off]=BIAS+r_add
        if not inrw(r_off):
            print("   !! RELATIVE writes to non-rw va 0x%x"%r_off); ok=False
# table ptr reloc
tbl=[r for r in rels if r[0]==0x45fe0]
chk(len(tbl)==1 and tbl[0][2]==0x40aa0,"tbl-ptr reloc @0x45fe0 addend=0x%x (want 0x40aa0)"%(tbl[0][2] if tbl else -1))
# entry1 field relocs
want={0x40a00+0x10:0x249d6,0x40a00+0x20:0x249f2,0x40a00+0x40:0x2d0f0,0x40a00+0x50:0x2d100,
      0x40a00+0x58:0x2d109,0x40a00+0x60:0x2d116,0x40a00+0x68:0x2d12b,0x40a00+0x88:0x1cb40,
      0x40aa0:0x459d0,0x40aa8:0x40a00}
got={r[0]:r[2] for r in rels if r[0] in want}
chk(got==want,"10 new relocs correct: %s"%("yes" if got==want else got))

# entry1 immediate bytes (file)
e1=va2off(0x40a00)
chk(d[e1]==0x01 and d[e1+1]==0x14,"entry1 byte0=01 byte1=0x%02x"%d[e1+1])
chk(d[e1+4:e1+8]==bytes([2,0,0,0]),"entry1 +0x04==2")
chk(d[e1+8:e1+12]==bytes([4,0,0,0]),"entry1 +0x08==4")
# array bytes (file, pre-reloc hold link VAs)
ar=va2off(0x40aa0)
a0,a1,a2=struct.unpack_from("<QQQ",d,ar)
chk(a0==0x459d0 and a1==0x40a00 and a2==0,"array file vals {0x%x,0x%x,0x%x}"%(a0,a1,a2))

# byte patches
chk(d[0x11f9c:0x11fa0]==bytes([0x00,0x00,0x80,0x12]),"fw-block movn")
chk(d[0x11fa0:0x11fa4]==bytes([0xc0,0x03,0x5f,0xd6]),"fw-block ret")
chk(d[0x1214c:0x12150]==bytes([0x20,0x00,0x80,0x52]),"crash-neuter movz")
chk(d[0x12150:0x12154]==bytes([0xc0,0x03,0x5f,0xd6]),"crash-neuter ret")

# SIMULATE type-table walk as the code does: ptr@0x45fe0 -> array -> entries
# after reloc: *[0x45fe0] = BIAS+0x40aa0 (array). array[0]=BIAS+0x459d0(entry0), array[1]=BIAS+0x40a00(entry1), [2]=0
arr_va=mem[0x45fe0]-BIAS
chk(arr_va==0x40aa0,"resolved tbl ptr -> array 0x%x"%arr_va)
e0=mem[0x40aa0]-BIAS; e1v=mem[0x40aa8]-BIAS
chk(e0==0x459d0,"array[0]->entry0 0x%x"%e0)
chk(e1v==0x40a00,"array[1]->entry1 0x%x"%e1v)
# entry0 byte1 (file) and entry1 byte1
chk(d[va2off(0x459d0)+1]==0x11,"entry0 byte1=0x11 (Q1/LCON)")
chk(d[va2off(0x40a00)+1]==0x14,"entry1 byte1=0x14 (Q2/Jedi)")

# original loadable content untouched (LOAD1 except our 2 patch sites, LOAD2)
import hashlib
stock=open("libsyncboss2.so","rb").read()
# LOAD1 0..0x34948 differs only at 0x11f9c-0x11fa4 and 0x1214c-0x12154
diffs=[i for i in range(0x34948) if d[i]!=stock[i]]
allowed=set(range(0x11f9c,0x11fa4))|set(range(0x1214c,0x12154))|{0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x38,0x39}
chk(all(x in allowed for x in diffs),"LOAD1 diffs only at patch sites + ehdr: %s"%[hex(x) for x in diffs if x not in allowed][:8])
# LOAD2 file 0x35778..0x36148 differs only in .dynamic (DT_RELA/RELASZ/RELACOUNT) and tbl-ptr area? tbl ptr value at 0x35fe0 unchanged in file (reloc handles it)
d2=[i for i in range(0x35778,0x36148) if d[i]!=stock[i]]
# expected: DT_RELA val(0x35ba8..b0), RELASZ(0x35bb8..c0), RELACOUNT(0x35c28..30)
exp=set(range(0x35ba8,0x35bb0))|set(range(0x35bb8,0x35bc0))|set(range(0x35c28,0x35c30))
chk(all(x in exp for x in d2),"LOAD2 diffs only in .dynamic tags: %s"%[hex(x) for x in d2 if x not in exp][:8])

print("\nRESULT:", "ALL PASS" if ok else "*** FAILURES ***")
