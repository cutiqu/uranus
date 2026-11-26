import sys, random
n=int(sys.argv[1]); seed=int(sys.argv[2]); only=None
if len(sys.argv)>3: only=int(sys.argv[3],16)  # fixed top nibble filter
r=random.Random(seed)
special=[0,1,2,0x7F,0x80,0xFF,0x7FFF,0x8000,0xFFFF,0x7FFFFFFF,0x80000000,0xFFFFFFFF,0x12345678,0xFFFFFF80,0x99,0x45]
def dn():
    k=r.random()
    if k<0.35: return r.choice(special)
    if k<0.5: return r.getrandbits(8)
    if k<0.6: return r.getrandbits(16)
    return r.getrandbits(32)
def an():
    if r.random()<0.92: return (r.randrange(0x10000,0xF00000)&~1)
    return r.getrandbits(32)
for i in range(n):
    s=r.getrandbits(32)
    sr=(r.getrandbits(5)) | (r.choice([0,0x2000])) | (r.randrange(8)<<8)
    usp=(r.randrange(0x10000,0xF00000)&~1); ssp=(r.randrange(0x10000,0xF00000)&~1)
    op=r.getrandbits(16)
    if only is not None: op=(op&0x0FFF)|(only<<12)
    w=[op]+[r.getrandbits(16) for _ in range(4)]
    vals=[s]+[dn() for _ in range(8)]+[an() for _ in range(7)]+[usp,ssp,0x1000,sr]+w
    print(" ".join("%x"%x for x in vals))
