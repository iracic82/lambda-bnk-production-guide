"""Rebuilds index.html from tools/kit-template.html and the kit's own files. Run from the kit root:
  python3 tools/build-kit.py
"""
import html,re,sys,pathlib
K=pathlib.Path(__file__).resolve().parent.parent; T=K/"tools/kit-template.html"
rd=lambda p:p.read_text()
files={"INF_SPEC":K/"contracts/inference-gateway.openapi.yaml","FW_SPEC":K/"contracts/network-firewall.openapi.yaml",
 "IRULE":K/"docs/samples/irule-api-auth.tcl","VALUES":K/"chart/values.yaml","WALK":K/"scripts/api-walkthrough.sh",
 "PRODVALS":K/"values-production.yaml","LABVALS":K/"values-lab.yaml"}
txt={k:rd(v).rstrip("\n") for k,v in files.items()}
docs=[d for d in rd(K/"docs/samples/endpoint-objects.yaml").split("\n---\n") if "kind: F5BigCneIrule" not in d]
txt["MANIFESTS"]="\n---\n".join(docs).rstrip("\n")
out=T.read_text()
for k,v in txt.items():
    out=out.replace("{{"+k+"_LINES}}",str(v.count("\n")+1))
    out=out.replace("{{"+k+"}}",html.escape(v,quote=False))
out=out.replace("{{INF_LINES}}",str(txt["INF_SPEC"].count("\n")+1)).replace("{{FW_LINES}}",str(txt["FW_SPEC"].count("\n")+1))
left=re.findall(r"\{\{[A-Z_]+\}\}",out); assert not left,left
(K/"index.html").write_text(out); print("index.html",len(out))

# ---- lab view: rendered straight from LAB.md, so the HTML shows exactly the tested commands ----
def md_inline(t):
    t=html.escape(t,quote=False)
    t=re.sub(r"`([^`]+)`",r"<code>\1</code>",t)
    t=re.sub(r"\*\*([^*]+)\*\*",r"<strong>\1</strong>",t)
    t=re.sub(r"\[([^\]]+)\]\(([^)]+)\)",r'<a href="\2">\1</a>',t)
    return t
def md_body(md):
    out=[];para=[];i=0;lines=md.split("\n")
    flush=lambda: (out.append("<p>"+md_inline(" ".join(para))+"</p>"),para.clear()) if para else None
    while i<len(lines):
        l=lines[i]
        if l.startswith("```"):
            flush(); j=i+1
            while not lines[j].startswith("```"): j+=1
            code="\n".join(lines[i+1:j])
            out.append('<div class="code"><div class="label"><span>'+(l[3:] or "text")+'</span><button class="copy" type="button">Copy</button></div><pre>'+html.escape(code,quote=False)+'</pre></div>')
            i=j+1; continue
        if not l.strip(): flush()
        else: para.append(l.strip())
        i+=1
    flush(); return "\n".join(out)
lab=rd(K/"LAB.md")
secs=re.split(r"^## ",lab,flags=re.M)[1:]
items=[]
for sec in secs:
    title,body=sec.split("\n",1)
    title=re.sub(r"^\d+\.\s*","",title.strip())
    items.append('<li><h3>'+md_inline(title)+'</h3><div class="body">'+md_body(body)+'</div></li>')
labhtml='<ol class="steps">\n'+"\n".join(items)+"\n</ol>"
a=out.index('id="view-lab"'); b=out.index('<ol class="steps">',a); c=out.index('</ol>',b)+5
out=out[:b]+labhtml+out[c:]
(K/"index.html").write_text(out); print("lab view from LAB.md:",len(items),"steps")
