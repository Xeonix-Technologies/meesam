"""Converts the legal texts of record (docs/03-legal/*.pdf) into the page content the web app shows.

  for f in docs/03-legal/*.pdf; do pdftotext -layout "$f" "/tmp/meesam-legal/$(basename "$f" .pdf | sed 's/MSM — //; s/ v0.1.*//; s/ /_/g').txt"; done
  python3 infra/tools/legal2md.py /tmp/meesam-legal

The text is taken as it stands in the PDF; nothing is reworded. The "Notes for review" section of each
document is internal and is left out. Output: apps/web/content/legal/<slug>.en.md and legal.generated.ts.
"""
import re, sys, os
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
SRC=sys.argv[1] if len(sys.argv)>1 else '/tmp/meesam-legal'   # folder of `pdftotext -layout` outputs, one <Name>.txt per PDF
OUT=os.path.join(ROOT,'apps','web','content','legal')
DOCS={'Terms_of_Use':'terms','Privacy_Policy':'privacy','Cookie_Notice':'cookies','Acceptable_Use_Policy':'acceptable-use','AI_and_Watch_Notice':'ai-and-watch'}
CTRL=re.compile('[‪-‮​-‏⁦-⁩﻿]')
def clean(s):
    s=CTRL.sub('',s)
    return s.replace('امارات. ميسم','ميسم.امارات').replace('امارات. ميسم','ميسم.امارات').replace('امارات.ميسم','ميسم.امارات')
def gaps(line):
    return [m.start() for m in re.finditer(r'(?<=\S)\s{2,}(?=\S)', line)]
def colstarts(line):
    return [m.start() for m in re.finditer(r'(?:(?<=\s\s)|^)\S', line) if m.start()==0 or line[m.start()-2:m.start()].strip()=='']
def convert(name):
    raw=open(f'{SRC}/{name}.txt',encoding='utf-8').read().replace('\f','\n')
    lines=[clean(l.rstrip()) for l in raw.split('\n')]
    title=None; out=[]; body=[]
    for l in lines:
        if re.match(r'^\s*Page \d+ of \d+\s*$', l): continue
        if re.match(r'^Meesam \(.*\)\s*.*$', l) and ('—' in l or 'ميسم' in l):
            if title is None: title=re.sub(r'^Meesam \(.*?\)\s*','',l).replace('—','').replace('ميسم','').replace(')','').strip()
            continue
        body.append(l)
    # cut at the internal review notes
    for i,l in enumerate(body):
        if l.strip().lower().startswith('notes for review'): body=body[:i]; break
    date=None
    i=0; n=len(body)
    para=[]; 
    def flush():
        if para: out.append(' '.join(x.strip() for x in para)); out.append(''); para.clear()
    while i<n:
        l=body[i]
        s=l.strip()
        if not s: flush(); i+=1; continue
        m=re.match(r'^\s*((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w* \d{1,2}, \d{4})', s.replace('​',''))
        if date is None and m: date=m.group(1); i+=1; continue
        if s.startswith('Draft v0.') :
            # the draft status paragraph is replaced by the page's own banner
            while i<n and body[i].strip(): i+=1
            continue
        if re.match(r'^\d+\. \S', s) and not re.match(r'^\d+\.\d', s) and len(s)<90 and l.startswith(s[:3]):
            flush(); out.append('## '+s); out.append(''); i+=1; continue
        # a table: an indented line with at least two wide gaps, followed (after blanks) by more such lines
        if l.startswith('  ') and len(gaps(l))>=1 and len(colstarts(l))>=2 and not re.match(r'^\d+\.\d', s):
            flush()
            cols=colstarts(l)
            head=[l[a:b].strip() for a,b in zip(cols, cols[1:]+[None])]
            rows=[]; cur=None; i+=1; blank=0
            while i<n:
                t=body[i]
                if not t.strip():
                    blank+=1; i+=1
                    if cur is not None: rows.append(cur); cur=None
                    continue
                if not t.startswith('  ') or re.match(r'^\s{0,1}\d+\.\d? ', t) : break
                # the table continues on the next page under a repeated header: take the new column positions
                tc=colstarts(t)
                if [t[a:b].strip() for a,b in zip(tc, tc[1:]+[None])]==head:
                    cols=tc; i+=1; continue
                cells=[]
                for a,b in zip(cols, cols[1:]+[None]):
                    # a cell may start a character or two left of its header
                    seg=t[max(a-1,0):(b-1 if b else None)] if a>0 else t[:(b-1 if b else None)]
                    cells.append(seg.strip())
                if cur is None: cur=cells
                else: cur=[(x+' '+y).strip() for x,y in zip(cur,cells)]
                i+=1
            if cur is not None: rows.append(cur)
            out.append('| '+' | '.join(head)+' |'); out.append('|'+' --- |'*len(head))
            for r in rows: out.append('| '+' | '.join(c.replace('|','/') for c in r)+' |')
            out.append(''); continue
        m=re.match(r'^(\d+\.\d+(?:\.\d+)?) (.*)$', s)
        if m: flush(); para.append(f'**{m.group(1)}** {m.group(2)}'); i+=1; continue
        m=re.match(r'^([•\-–]|\([a-z]\)|\d+\))\s+(.*)$', s)
        if m and l.startswith(' '):
            flush(); para.append(('- ' if m.group(1) in '•-–' else f'- {m.group(1)} ')+m.group(2)); i+=1
            while i<n and body[i].strip() and not re.match(r'^\s*([•\-–]|\([a-z]\)|\d+\))\s', body[i]) and not re.match(r'^\d+\.', body[i].strip()): para.append(body[i]); i+=1
            if para: out.append(' '.join(x.strip() for x in para)); para.clear()
            continue
        # a plain list: lines indented a few spaces with no bullet sign; an item ends at a line ending in ";" or "."
        if re.match(r'^ {4,8}\S', l) and not gaps(l):
            flush(); item=[]
            while i<n and re.match(r'^ {4,8}\S', body[i]) and not gaps(body[i]):
                item.append(body[i].strip()); i+=1
                if item[-1][-1] in ';.': out.append('- '+' '.join(item)); item=[]
            if item: out.append('- '+' '.join(item))
            out.append(''); continue
        para.append(l); i+=1
    flush()
    md=f'# {title}\n\n<!-- source: docs/03-legal/MSM — {name.replace("_"," ")} v0.1 (draft, 2026-11-12).pdf; dated {date}; the "Notes for review" section is internal and is not published -->\n\n'+'\n'.join(out).strip()+'\n'
    md=re.sub(r'\n{3,}','\n\n',md)
    # pdftotext writes the Arabic domain name in visual order and loses the space after it
    md=md.replace('\u0627\u0645\u0627\u0631\u0627\u062a.( \u0645\u064a\u0633\u0645together','\u0645\u064a\u0633\u0645.\u0627\u0645\u0627\u0631\u0627\u062a (together')
    md=re.sub('([\u0600-\u06FF])([A-Za-z])', r'\1 \2', md)
    open(f'{OUT}/{DOCS[name]}.en.md','w',encoding='utf-8').write(md)
    return title,date,len(md)
import json
meta={}
for k in DOCS:
    title,date,_=convert(k); meta[DOCS[k]]={'title':title,'date':date}
    print(k, title, date)
ts='// Generated by infra/tools/legal2md.py from docs/03-legal/*.pdf. Do not edit by hand: change the document of record and regenerate.\n'
ts+='export const LEGAL_VERSION = "v0.1-draft-2026-11-12";\n'
ts+='export const LEGAL_DOCS = {\n'
for slug,m in meta.items():
    md=open(f'{OUT}/{slug}.en.md',encoding='utf-8').read()
    md=re.sub(r'^# .*\n\n<!--.*?-->\n\n','',md,flags=re.S)
    ts+=f'  {json.dumps(slug)}: {{ title: {json.dumps(m["title"])}, dated: {json.dumps(m["date"])}, body: {json.dumps(md, ensure_ascii=False)} }},\n'
ts+='} as const;\nexport type LegalSlug = keyof typeof LEGAL_DOCS;\n'
ts+='\n/** What a new user accepts (Terms, Acceptable Use, AI and Watch Notice) and acknowledges (Privacy Policy) at sign-up. */\nexport const CONSENT_DOCUMENTS: LegalSlug[] = ["terms", "acceptable-use", "ai-and-watch", "privacy"];\n'
open(os.path.join(ROOT,'apps','web','content','legal.generated.ts'),'w',encoding='utf-8').write(ts)
