import struct, hashlib

SRC="libsyncboss.stock.so"   # stock base, shipped alongside this script
OUT="libsyncboss_appended1.so"
d=bytearray(open(SRC,"rb").read())
assert hashlib.sha1(bytes(d)).hexdigest()=="85a1788113f1faff2af91cd204f9d59a01e1040a", "base not stock"

# ---- parse header ----
e_phoff,=struct.unpack_from("<Q",d,0x20)
e_phentsize,e_phnum=struct.unpack_from("<HH",d,0x36)
assert e_phentsize==56
# dynamic value offsets (from elf_plan): recompute to be safe
# find PT_DYNAMIC
dyn_off=None
for i in range(e_phnum):
    o=e_phoff+i*e_phentsize
    pt,=struct.unpack_from("<I",d,o)
    poff,pva=struct.unpack_from("<QQ",d,o+8)[0], struct.unpack_from("<QQ",d,o+8)[1]
    if pt==2: dyn_off=poff
assert dyn_off is not None
DT={}
o=dyn_off
while True:
    tag,val=struct.unpack_from("<qQ",d,o)
    DT[tag]=(o+8,val)   # (file offset of value, value)
    if tag==0: break
    o+=16
RELA_off, RELA=DT[7]; RELASZ_off,RELASZ=DT[8]; RELACOUNT_off,RELACOUNT=DT[0x6ffffff9]
assert RELA==0x4088 and RELASZ==0x750 and RELACOUNT==0x4d
nrel=RELASZ//24
print("orig relocs=%d relacount=%d"%(nrel,RELACOUNT))

# ---- read original reloc table, split relative-prefix / rest ----
relocs=[]
for i in range(nrel):
    r_off,r_info,r_add=struct.unpack_from("<QQq",d,RELA+i*24)
    relocs.append([r_off,r_info,r_add])
# edit table-ptr reloc (r_off==0x45fe0) addend later once new array VA known
# entry0 pointer reloc addends (for entry1 copy)
ENTRY0_VA=0x459d0
ent0_relocs={0x10:0x249d6,0x20:0x249f2,0x40:0x2d0f0,0x50:0x2d100,0x58:0x2d109,0x60:0x2d116,0x68:0x2d12b,0x88:0x1cb40}
# sanity: those relocs exist in table with r_off=ENTRY0_VA+delta
have={r[0]:r[2] for r in relocs}
for delta,add in ent0_relocs.items():
    assert have.get(ENTRY0_VA+delta)==add, "entry0 reloc mismatch @+0x%x"%delta
RELATIVE=0x403

# ---- layout of new segment ----
NEW_FOFF=0x40000
NEW_VA  =NEW_FOFF          # VA must equal file offset: bionic locates phdr at elf_base+e_phoff
PHT_SZ=(e_phnum+1)*56                      # 8 phdrs
reltab_foff=NEW_FOFF+PHT_SZ
new_nrel=nrel+9
reltab_sz=new_nrel*24
entry1_foff=reltab_foff+reltab_sz
entry1_va = NEW_VA+(entry1_foff-NEW_FOFF)
array_foff=entry1_foff+0xa0
array_va  = NEW_VA+(array_foff-NEW_FOFF)
seg_end_foff=array_foff+0x18
seg_sz=seg_end_foff-NEW_FOFF
newpht_va=NEW_VA                             # PHT at seg start
print("PHT@0x%x reltab@0x%x(va0x%x) entry1@0x%x(va0x%x) array@0x%x(va0x%x) segsz=0x%x"%(
    NEW_FOFF,reltab_foff,NEW_VA+PHT_SZ,entry1_foff,entry1_va,array_foff,array_va,seg_sz))

# ---- build entry1 = copy of entry0, byte1=0x14 ----
entry1=bytearray(d[0x359d0:0x359d0+0xa0])
assert entry1[0]==0x01 and entry1[1]==0x11
entry1[1]=0x14
import struct as _s; _s.pack_into("<I",entry1,4,4)

# ---- build new array {entry0_va, entry1_va, NULL} ----
new_array=struct.pack("<QQQ",entry1_va,0,0)

# ---- new relocs: entry1 pointers (8) + array slots (2) ----
new_relocs=[]
for delta,add in ent0_relocs.items():
    new_relocs.append([entry1_va+delta,RELATIVE,add])
new_relocs.append([array_va+0x00,RELATIVE,entry1_va])
assert len(new_relocs)==9

# ---- assemble new reloc table: relative-prefix(77) + new(10) + rest(1) ----
prefix=relocs[:RELACOUNT]; rest=relocs[RELACOUNT:]
# edit table-ptr reloc addend -> new array
edited=0
for r in prefix:
    if r[0]==0x45fe0:
        assert r[2]==0x46008; r[2]=array_va; edited+=1
assert edited==1, "tbl ptr reloc not found/edited"
merged=prefix+new_relocs+rest
assert len(merged)==new_nrel
newRELACOUNT=RELACOUNT+9
reltab=b"".join(struct.pack("<QQq",a,b,c) for a,b,c in merged)
assert len(reltab)==reltab_sz

# ---- byte patches in LOAD1: fw-block + crash-neuter ----
def patch(off,want,new):
    assert d[off:off+4]==bytes(want),"precheck @0x%x got %s"%(off,d[off:off+4].hex())
    d[off:off+4]=bytes(new)
patch(0x11f9c,[0xff,0x83,0x01,0xd1],[0x00,0x00,0x80,0x12])   # fw-block movn w0,#-1
patch(0x11fa0,[0xf9,0x63,0x02,0xa9],[0xc0,0x03,0x5f,0xd6])   # ret
patch(0x1214c,[0xff,0xc3,0x01,0xd1],[0x20,0x00,0x80,0x52])   # crash-neuter movz w0,#1
patch(0x12150,[0xf8,0x1b,0x00,0xf9],[0xc0,0x03,0x5f,0xd6])   # ret

# ---- build new PHT (copy 7, add PT_LOAD) ----
pht=bytearray()
for i in range(e_phnum):
    pht+=d[e_phoff+i*e_phentsize:e_phoff+(i+1)*e_phentsize]
newseg=struct.pack("<IIQQQQQQ",1,6,NEW_FOFF,NEW_VA,NEW_VA,seg_sz,seg_sz,0x10000)
pht+=newseg
assert len(pht)==PHT_SZ

# ---- assemble output: pad to NEW_FOFF, then [PHT][reltab][entry1][array] ----
if len(d)<NEW_FOFF: d+=b"\x00"*(NEW_FOFF-len(d))
else: assert False,"file already >= NEW_FOFF"
seg=bytearray()
seg+=pht
seg+=reltab
seg+=entry1
seg+=new_array
assert len(seg)==seg_sz
d+=seg

# ---- patch ELF header: e_phoff, e_phnum ----
struct.pack_into("<Q",d,0x20,NEW_FOFF)      # e_phoff -> new PHT
struct.pack_into("<H",d,0x38,e_phnum+1)     # e_phnum -> 8
# ---- patch .dynamic: DT_RELA, DT_RELASZ, DT_RELACOUNT ----
struct.pack_into("<Q",d,RELA_off,reltab_foff-NEW_FOFF+NEW_VA)   # =reltab VA
struct.pack_into("<Q",d,RELASZ_off,reltab_sz)
struct.pack_into("<Q",d,RELACOUNT_off,newRELACOUNT)

open(OUT,"wb").write(d)
print("wrote %s size=0x%x sha1=%s"%(OUT,len(d),hashlib.sha1(bytes(d)).hexdigest()))
print("DT_RELA->0x%x RELASZ=0x%x RELACOUNT=%d"%(reltab_foff-NEW_FOFF+NEW_VA,reltab_sz,newRELACOUNT))
