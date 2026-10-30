#!/usr/bin/env python3
"""Syntax-check the session scripts and every sh -c script embedded in them, at every
nesting level, with dash and busybox sh. Usage: scripts/check-shell.py switcher/assets/*.sh
(run 44: a quote in a comment inside the UI activator string passed dash -n on the file
but broke the activator itself)."""
import re, subprocess, sys, os, tempfile
def dq_unescape(s):
    out=[];i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s) and s[i+1] in '"$`\\\n':
            if s[i+1]!='\n': out.append(s[i+1])
            i+=2; continue
        out.append(c); i+=1
    return ''.join(out)
def extract(text):
    # find  sh -c "<body>"  and  sh -c '<body>'
    res=[]
    for m in re.finditer(r'sh -c (["\'])', text):
        q=m.group(1); i=m.end(); j=i
        if q=="'":
            j=text.find("'",i); 
            if j<0: continue
            res.append(("'",text[i:j],m.start())); continue
        while j<len(text):
            if text[j]=='\\': j+=2; continue
            if text[j]=='"': break
            j+=1
        res.append(('"',text[i:j],m.start()))
    return res
def check(body,label,depth,fails,total):
    total[0]+=1
    with tempfile.NamedTemporaryFile('w',suffix='.sh',delete=False) as f: f.write(body); fn=f.name
    for sh in (['dash','-n',fn],['busybox','sh','-n',fn]):
        r=subprocess.run(sh,capture_output=True,text=True)
        if r.returncode: fails.append(f"{label} depth{depth} [{sh[0]}]: {r.stderr.strip()[:200]}")
    os.unlink(fn)
    for q,b,pos in extract(body):
        inner = dq_unescape(b) if q=='"' else b
        # outer variables appear as $NAME: harmless for -n
        check(inner,label+f"@{pos}",depth+1,fails,total)
fails=[];total=[0]
for p in sys.argv[1:]:
    t=open(p).read()
    for q,b,pos in extract(t):
        inner = dq_unescape(b) if q=='"' else b
        line=t.count('\n',0,pos)+1
        check(inner,f"{os.path.basename(p)}:{line}",1,fails,total)
print(f"embedded scripts checked: {total[0]}"); print("\n".join(fails) if fails else "all parse in dash and busybox")
