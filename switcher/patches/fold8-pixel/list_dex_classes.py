import zipfile,struct,sys,re
with zipfile.ZipFile(sys.argv[1]) as z:
 for name in z.namelist():
  if not name.endswith('.dex'):continue
  d=z.read(name)
  u=lambda o:struct.unpack_from('<I',d,o)[0]
  strings=[]
  for i in range(u(56)):
   p=u(u(60)+i*4)
   while d[p]&128:p+=1
   p+=1
   strings.append(d[p:d.index(b'\0',p)].decode('utf-8','replace'))
  types=[strings[u(u(68)+i*4)] for i in range(u(64))]
  for i in range(u(96)):
   s=types[u(u(100)+i*32)]
   if re.search(sys.argv[2],s,re.I):print(s[1:-1].replace('/','.'))
