#!/bin/bash
# Script de déploiement RAG Configurator v5
# Refonte complète : architecture par projet, préfixes de contexte regex, test de règles

set -e

APP_DIR="/opt/pdf-chunker"
BACKUP_DIR="/tmp/pdf-chunker-data-backup-$(date +%s)"

echo "=== 1. Arrêt du service ==="
systemctl stop pdf-chunker || true

echo "=== 2. Sauvegarde des données ==="
if [ -d "$APP_DIR/data" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -r "$APP_DIR/data" "$BACKUP_DIR/"
    echo "Données sauvegardées dans $BACKUP_DIR"
fi

echo "=== 3. Nettoyage ==="
rm -rf "$APP_DIR/templates"
rm -f  "$APP_DIR/main.py"
rm -f  "$APP_DIR/requirements.txt"
mkdir -p "$APP_DIR/templates" "$APP_DIR/static" "$APP_DIR/data/projects"
chown -R ubuntu:ubuntu "$APP_DIR"

echo "=== 4. SECRET_KEY ==="
EXISTING_KEY=$(grep -oP '(?<=SECRET_KEY=)[^ ]+' /etc/systemd/system/pdf-chunker.service 2>/dev/null || true)
if [ -z "$EXISTING_KEY" ]; then
    GENERATED_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    echo "Nouvelle clé générée : $GENERATED_KEY"
else
    GENERATED_KEY="$EXISTING_KEY"
    echo "Clé existante conservée."
fi

echo "=== 5. requirements.txt ==="
cat > "$APP_DIR/requirements.txt" << 'EOF'
fastapi==0.115.6
uvicorn[standard]==0.32.1
python-multipart==0.0.20
jinja2==3.1.4
itsdangerous==2.2.0
pymupdf4llm==0.3.4
EOF

echo "=== 6. main.py ==="
cat > "$APP_DIR/main.py" << 'EOFPY'
#!/usr/bin/env python3
import fcntl, json, os, re, secrets, hashlib, zipfile, io
from datetime import datetime
from pathlib import Path

import fitz
import pymupdf4llm
from fastapi import FastAPI, File, Form, Request, UploadFile, HTTPException
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeTimedSerializer

APP_PASSWORD = os.environ.get("APP_PASSWORD", "Baclain1!")
SECRET_KEY   = os.environ.get("SECRET_KEY", "CHANGEME_FIXED_KEY")
DATA_DIR     = Path("/opt/pdf-chunker/data")
PROJECTS_DIR = DATA_DIR / "projects"
PRESETS_FILE = DATA_DIR / "presets.json"

for d in (DATA_DIR, PROJECTS_DIR):
    d.mkdir(parents=True, exist_ok=True)

if not PRESETS_FILE.exists():
    default_presets = [{
        "id": "default_moniteur", "name": "Moniteur belge",
        "removals": [r"\n\nPage \d+ de \d+ Copyright Moniteur belge \d{2}-\d{2}-\d{4}\n\n"],
        "splits": [r"\n\n(Art\. \d+:\d+)"],
        "prefix_rules": []
    }]
    PRESETS_FILE.write_text(json.dumps(default_presets, ensure_ascii=False, indent=2), encoding="utf-8")

serializer = URLSafeTimedSerializer(SECRET_KEY)
app = FastAPI(title="RAG Configurator")
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

# ── Auth ──────────────────────────────────────────────────────────────────────

def check_auth(request: Request) -> bool:
    token = request.cookies.get("session")
    if not token: return False
    try:
        serializer.loads(token, max_age=86400 * 7)
        return True
    except Exception: return False

# ── JSON helpers ──────────────────────────────────────────────────────────────

def load_json_file(path: Path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            data = json.load(f)
            fcntl.flock(f, fcntl.LOCK_UN)
            return data
    except Exception:
        return default

def save_json_file(path: Path, data):
    tmp = path.with_suffix(".tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush(); os.fsync(f.fileno())
            fcntl.flock(f, fcntl.LOCK_UN)
        tmp.replace(path)
    except Exception:
        if tmp.exists(): tmp.unlink()

def load_presets():  return load_json_file(PRESETS_FILE, [])
def save_presets(d): save_json_file(PRESETS_FILE, d)

# ── Project helpers ───────────────────────────────────────────────────────────

def project_dir(pid: str) -> Path:
    return PROJECTS_DIR / pid

def load_project(pid: str):
    p = project_dir(pid) / "project.json"
    if not p.exists(): return None
    return load_json_file(p, None)

def save_project(pid: str, data: dict):
    save_json_file(project_dir(pid) / "project.json", data)

def list_projects() -> list:
    result = []
    for d in sorted(PROJECTS_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
        if d.is_dir():
            p = load_json_file(d / "project.json", None)
            if p: result.append(p)
    return result

# ── Chunking ──────────────────────────────────────────────────────────────────

def estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4)

def apply_chunking(md_text: str, removals: list, splits: list,
                   prefix_rules: list, manual_labels: dict,
                   max_size: int = 2500, add_markers: bool = True) -> list:
    # 1. Suppressions
    for r in removals:
        if r and r.strip():
            try: md_text = re.sub(r, " ", md_text)
            except: pass

    # 2. Splits
    segments = [md_text]
    for s in splits:
        if s and s.strip():
            new_segments = []
            for seg in segments:
                try:
                    safe_s = f"(?:{s})"
                    parts = re.split(f"({safe_s})", seg)
                    if len(parts) > 1:
                        res = [parts[0]]
                        for i in range(1, len(parts), 2):
                            suffix = parts[i+1] if i+1 < len(parts) else ""
                            res.append(parts[i] + suffix)
                        new_segments.extend(res)
                    else:
                        new_segments.append(seg)
                except Exception:
                    new_segments.append(seg)
            segments = new_segments

    # 3. Sub-split large segments
    raw_chunks = []
    for seg in segments:
        seg = seg.strip()
        if not seg: continue
        if len(seg) <= max_size:
            raw_chunks.append(seg)
        else:
            start = 0
            while start < len(seg):
                end = start + max_size
                chunk = seg[start:end]
                if add_markers:
                    if start > 0: chunk = "> [!NOTE] SUITE du segment précédent...\n\n" + chunk
                    if end < len(seg): chunk = chunk + "\n\n> [!IMPORTANT] Cet article est TRONQUÉ, la suite au segment suivant."
                raw_chunks.append(chunk)
                start += max_size

    # 4. Apply prefix rules + manual labels
    result = []
    for i, chunk in enumerate(raw_chunks):
        prefix_label = None
        resolved = False

        for rule in prefix_rules:
            pattern = rule.get("pattern", "").strip()
            label   = rule.get("label", "").strip()
            if not pattern: continue
            try:
                if re.search(pattern, chunk):
                    prefix_label = label
                    resolved = True
                    break
            except Exception:
                continue

        if not resolved:
            group_key = f"chunk_{i}"
            if group_key in manual_labels:
                prefix_label = manual_labels[group_key] or None
                resolved = True  # explicitly handled, even if empty

        final_text = f"[{prefix_label}]\n\n{chunk}" if prefix_label else chunk
        result.append({
            "index": i, "text": final_text, "raw_text": chunk,
            "prefix_label": prefix_label, "resolved": resolved
        })

    return result

def chunks_to_md(chunks: list) -> str:
    return "\n\n---\n\n".join(c["text"] for c in chunks)

def analyze_chunks(chunks: list) -> dict:
    if not chunks: return {}
    sizes  = [len(c["text"]) for c in chunks]
    tokens = [estimate_tokens(c["text"]) for c in chunks]
    buckets = {"<500": 0, "500-1000": 0, "1000-2500": 0, ">2500": 0}
    for s in sizes:
        if s < 500: buckets["<500"] += 1
        elif s < 1000: buckets["500-1000"] += 1
        elif s <= 2500: buckets["1000-2500"] += 1
        else: buckets[">2500"] += 1
    unresolved = sum(1 for c in chunks if not c["resolved"])
    return {
        "total": len(chunks), "max_size": max(sizes), "avg_size": int(sum(sizes)/len(sizes)),
        "max_tokens": max(tokens), "avg_tokens": int(sum(tokens)/len(tokens)),
        "buckets": buckets, "unresolved": unresolved
    }

def find_unresolved_groups(chunks: list) -> list:
    groups = []
    i = 0
    while i < len(chunks):
        if not chunks[i]["resolved"]:
            start = i
            preview = chunks[i]["raw_text"][:300]
            while i < len(chunks) and not chunks[i]["resolved"]:
                i += 1
            end = i - 1
            groups.append({
                "start": start, "end": end,
                "count": end - start + 1,
                "preview": preview,
                "key": f"group_{start}_{end}"
            })
        else:
            i += 1
    return groups

# ── Routes : Auth ─────────────────────────────────────────────────────────────

@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    return templates.TemplateResponse("login.html", {"request": request, "error": None})

@app.post("/login")
async def do_login(request: Request, password: str = Form(...)):
    if password == APP_PASSWORD:
        token = serializer.dumps("authenticated")
        resp = RedirectResponse("/", status_code=302)
        resp.set_cookie("session", token, httponly=True, max_age=86400 * 7)
        return resp
    return templates.TemplateResponse("login.html", {"request": request, "error": "Mot de passe incorrect."})

@app.get("/logout")
async def logout():
    resp = RedirectResponse("/login", status_code=302)
    resp.delete_cookie("session")
    return resp

# ── Routes : Main ─────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    if not check_auth(request): return RedirectResponse("/login")
    return templates.TemplateResponse("index.html", {
        "request": request,
        "projects": list_projects(),
        "presets": load_presets()
    })

@app.get("/project/{pid}", response_class=HTMLResponse)
async def project_page(request: Request, pid: str):
    if not check_auth(request): return RedirectResponse("/login")
    proj = load_project(pid)
    if not proj: raise HTTPException(404)
    return templates.TemplateResponse("project.html", {
        "request": request, "project": proj, "presets": load_presets()
    })

# ── Routes : Projects ─────────────────────────────────────────────────────────

@app.post("/projects")
async def create_project(request: Request):
    if not check_auth(request): raise HTTPException(401)
    data = await request.json()
    pid  = secrets.token_hex(6)
    proj = {
        "id": pid,
        "name": data.get("name", "Sans titre"),
        "description": data.get("description", ""),
        "created_at": datetime.now().isoformat(),
        "status": "empty",
        "filename": None,
        "rules": {
            "removals": [], "splits": [], "prefix_rules": [],
            "max_size": 2500, "add_markers": True
        },
        "manual_labels": {},
        "stats": None
    }
    project_dir(pid).mkdir(parents=True, exist_ok=True)
    save_project(pid, proj)
    return JSONResponse(proj)

@app.delete("/projects/{pid}")
async def delete_project(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    import shutil
    d = project_dir(pid)
    if d.exists(): shutil.rmtree(d)
    return JSONResponse({"ok": True})

# ── Routes : Upload PDF ───────────────────────────────────────────────────────

@app.post("/projects/{pid}/upload")
async def upload_pdf(
    request: Request, pid: str,
    file: UploadFile = File(...),
    page_start: str = Form(""), page_end: str = Form("")
):
    if not check_auth(request): raise HTTPException(401)
    proj = load_project(pid)
    if not proj: raise HTTPException(404)

    content  = await file.read()
    pdf_path = project_dir(pid) / "source.pdf"
    pdf_path.write_bytes(content)

    pages = None
    try:
        if page_start or page_end:
            p_doc   = fitz.open(str(pdf_path))
            p_start = int(page_start) if page_start else 1
            p_end   = int(page_end)   if page_end   else p_doc.page_count
            pages   = list(range(max(0, p_start-1), min(p_doc.page_count, p_end)))
            p_doc.close()
    except: pass

    raw_md = pymupdf4llm.to_markdown(str(pdf_path), pages=pages)
    (project_dir(pid) / "raw.md").write_bytes(raw_md.encode("utf-8"))

    proj["filename"] = file.filename
    proj["status"]   = "raw"
    proj["stats"]    = None
    save_project(pid, proj)

    return JSONResponse({"ok": True, "chars": len(raw_md)})

# ── Routes : Generate ─────────────────────────────────────────────────────────

@app.post("/projects/{pid}/generate")
async def generate(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    proj = load_project(pid)
    if not proj: raise HTTPException(404)

    raw_path = project_dir(pid) / "raw.md"
    if not raw_path.exists(): raise HTTPException(400, "Raw MD manquant — uploadez d'abord le PDF.")

    data          = await request.json()
    rules         = data.get("rules", proj["rules"])
    manual_labels = data.get("manual_labels", proj.get("manual_labels", {}))
    accept_unresolved = data.get("accept_unresolved", False)

    raw_text = raw_path.read_text(encoding="utf-8")
    chunks   = apply_chunking(
        raw_text,
        rules.get("removals", []),
        rules.get("splits", []),
        rules.get("prefix_rules", []),
        manual_labels,
        max_size=rules.get("max_size", 2500),
        add_markers=rules.get("add_markers", True)
    )

    stats             = analyze_chunks(chunks)
    unresolved_groups = find_unresolved_groups(chunks)
    done              = not unresolved_groups or accept_unresolved

    if done:
        md_out = chunks_to_md(chunks)
        (project_dir(pid) / "chunks.md").write_bytes(md_out.encode("utf-8"))
        proj["status"] = "done"
    else:
        proj["status"] = "configured"

    proj["rules"]         = rules
    proj["manual_labels"] = manual_labels
    proj["stats"]         = stats
    save_project(pid, proj)

    preview = [
        {"index": c["index"]+1, "size": len(c["text"]),
         "tokens": estimate_tokens(c["text"]), "text": c["raw_text"][:800],
         "prefix_label": c["prefix_label"], "resolved": c["resolved"]}
        for c in chunks[:5]
    ]

    return JSONResponse({
        "stats": stats, "preview": preview,
        "unresolved_groups": unresolved_groups, "done": done
    })

# ── Routes : Test prefix rule ─────────────────────────────────────────────────

@app.post("/projects/{pid}/test-prefix")
async def test_prefix(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    proj = load_project(pid)
    if not proj: raise HTTPException(404)

    raw_path = project_dir(pid) / "raw.md"
    if not raw_path.exists(): raise HTTPException(400, "Raw MD manquant.")

    data    = await request.json()
    pattern = data.get("pattern", "").strip()
    rules   = data.get("rules", proj["rules"])

    if not pattern:
        return JSONResponse({"error": "Pattern vide"}, status_code=400)

    raw_text = raw_path.read_text(encoding="utf-8")
    chunks   = apply_chunking(
        raw_text,
        rules.get("removals", []),
        rules.get("splits", []),
        [], {},
        max_size=rules.get("max_size", 2500),
        add_markers=False
    )

    matches, no_matches = [], []
    try:
        compiled = re.compile(pattern)
        for c in chunks:
            if compiled.search(c["raw_text"]):
                matches.append({"index": c["index"]+1, "preview": c["raw_text"][:300]})
            else:
                no_matches.append({"index": c["index"]+1, "preview": c["raw_text"][:300]})
    except re.error as e:
        return JSONResponse({"error": f"Regex invalide : {e}"}, status_code=400)

    return JSONResponse({
        "match_count": len(matches), "no_match_count": len(no_matches),
        "matches": matches[:5], "no_matches": no_matches[:5]
    })

# ── Routes : Config export ────────────────────────────────────────────────────

@app.get("/projects/{pid}/export-config")
async def export_config(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    proj = load_project(pid)
    if not proj: raise HTTPException(404)
    export = {
        "name": proj["name"], "description": proj.get("description", ""),
        "rules": proj["rules"], "manual_labels": proj.get("manual_labels", {})
    }
    name = re.sub(r'[^\w\-]', '_', proj["name"]) + "_config.json"
    buf  = io.BytesIO(json.dumps(export, ensure_ascii=False, indent=2).encode("utf-8"))
    return StreamingResponse(buf, media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{name}"'})

# ── Routes : Downloads ────────────────────────────────────────────────────────

@app.get("/projects/{pid}/download/raw")
async def download_raw(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    path = project_dir(pid) / "raw.md"
    if not path.exists(): raise HTTPException(404)
    proj = load_project(pid)
    name = re.sub(r'[^\w\-.]', '_', f"{proj['name']}_raw.md" if proj else f"{pid}_raw.md")
    return FileResponse(path, filename=name, media_type="text/markdown")

@app.get("/projects/{pid}/download/chunks")
async def download_chunks(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    path = project_dir(pid) / "chunks.md"
    if not path.exists(): raise HTTPException(404)
    proj = load_project(pid)
    name = re.sub(r'[^\w\-.]', '_', f"{proj['name']}_chunks.md" if proj else f"{pid}_chunks.md")
    return FileResponse(path, filename=name, media_type="text/markdown")

@app.get("/projects/{pid}/download/zip")
async def download_zip(request: Request, pid: str):
    if not check_auth(request): raise HTTPException(401)
    path = project_dir(pid) / "chunks.md"
    if not path.exists(): raise HTTPException(404)
    proj = load_project(pid)
    base = re.sub(r'[^\w\-]', '_', proj['name'] if proj else pid)
    md   = path.read_text(encoding="utf-8")
    chunks = [c.strip() for c in md.split("\n\n---\n\n") if c.strip()]
    buf  = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for i, chunk in enumerate(chunks, 1):
            zf.writestr(f"{base}/chunk_{i:04d}.md", chunk)
    buf.seek(0)
    return StreamingResponse(buf, media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{base}_chunks.zip"'})

# ── Routes : Presets ──────────────────────────────────────────────────────────

@app.post("/presets")
async def save_preset(request: Request):
    if not check_auth(request): raise HTTPException(401)
    data = await request.json()
    presets = load_presets()
    new_p = {
        "id": secrets.token_hex(4), "name": data.get("name"),
        "removals": data.get("removals", []),
        "splits": data.get("splits", []),
        "prefix_rules": data.get("prefix_rules", [])
    }
    presets.append(new_p)
    save_presets(presets)
    return JSONResponse(new_p)

@app.delete("/presets/{p_id}")
async def delete_preset(request: Request, p_id: str):
    if not check_auth(request): raise HTTPException(401)
    save_presets([p for p in load_presets() if p["id"] != p_id])
    return JSONResponse({"ok": True})
EOFPY

echo "=== 7. Templates ==="

cat > "$APP_DIR/templates/login.html" << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RAG Configurator</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  body{background:#f7f7f5;color:#1a1a1a;font-family:'DM Sans',sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center}
  .card{background:#fff;border:1px solid #e5e5e2;padding:48px 40px;width:360px}
  .logo{font-family:'DM Mono',monospace;font-size:13px;font-weight:500;color:#1a1a1a;letter-spacing:0.05em;margin-bottom:36px}
  .logo span{color:#aaa}
  label{display:block;font-size:11px;letter-spacing:0.12em;text-transform:uppercase;color:#999;font-family:'DM Mono',monospace;margin-bottom:8px}
  input[type="password"]{width:100%;background:#f7f7f5;border:1px solid #e5e5e2;color:#1a1a1a;font-family:'DM Mono',monospace;font-size:13px;padding:10px 14px;outline:none;margin-bottom:20px;transition:border-color .15s}
  input[type="password"]:focus{border-color:#1a1a1a}
  button{width:100%;background:#1a1a1a;color:#fff;border:none;font-family:'DM Mono',monospace;font-size:11px;font-weight:500;letter-spacing:0.15em;text-transform:uppercase;padding:12px;cursor:pointer;transition:background .15s}
  button:hover{background:#333}
  .error{background:#fef2f2;border:1px solid #fca5a5;color:#dc2626;font-family:'DM Mono',monospace;font-size:11px;padding:10px 14px;margin-bottom:18px}
</style>
</head>
<body>
<div class="card">
  <div class="logo">RAG<span>/</span>Config</div>
  {% if error %}<div class="error">{{ error }}</div>{% endif %}
  <form method="post" action="/login">
    <label>Mot de passe</label>
    <input type="password" name="password" autofocus>
    <button type="submit">Connexion →</button>
  </form>
</div>
</body>
</html>
EOF

cat > "$APP_DIR/templates/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RAG Configurator</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  :root{--bg:#f7f7f5;--white:#fff;--border:#e5e5e2;--border-dark:#ccc;--text:#1a1a1a;--muted:#999;--muted2:#bbb;--accent:#1a1a1a;--blue:#2563eb;--red:#dc2626;--green:#16a34a;--mono:'DM Mono',monospace;--sans:'DM Sans',sans-serif}
  body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;font-size:14px}
  header{background:var(--white);border-bottom:1px solid var(--border);padding:0 32px;height:48px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100}
  .logo{font-family:var(--mono);font-size:12px;font-weight:500;letter-spacing:0.05em}
  .logo span{color:var(--muted)}
  .logout{font-family:var(--mono);font-size:11px;color:var(--muted);text-decoration:none}
  .logout:hover{color:var(--text)}
  .main{max-width:760px;margin:48px auto;padding:0 24px}
  .page-title{font-size:18px;font-weight:500;margin-bottom:8px}
  .page-sub{font-family:var(--mono);font-size:11px;color:var(--muted);margin-bottom:32px}
  .new-project-box{background:var(--white);border:1px solid var(--border);padding:20px 24px;margin-bottom:32px}
  .row{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
  .label{font-family:var(--mono);font-size:10px;letter-spacing:0.15em;text-transform:uppercase;color:var(--muted);margin-bottom:6px;display:block}
  input[type="text"]{width:100%;background:var(--bg);border:1px solid var(--border);color:var(--text);font-family:var(--mono);font-size:12px;padding:7px 10px;outline:none;transition:border-color .15s}
  input:focus{border-color:var(--accent)}
  .btn{font-family:var(--mono);font-size:11px;letter-spacing:0.1em;text-transform:uppercase;padding:8px 16px;cursor:pointer;border:1px solid var(--border);background:var(--white);color:var(--text);transition:all .15s}
  .btn:hover{border-color:var(--accent)}
  .btn-primary{background:var(--accent);color:#fff;border-color:var(--accent)}
  .btn-primary:hover{background:#333;border-color:#333}
  .btn-danger{color:var(--red)}
  .btn-danger:hover{border-color:var(--red);background:#fef2f2}
  .project-list{display:flex;flex-direction:column;gap:8px}
  .project-card{background:var(--white);border:1px solid var(--border);padding:16px 20px;display:flex;align-items:center;justify-content:space-between;cursor:pointer;transition:border-color .15s}
  .project-card:hover{border-color:var(--border-dark)}
  .project-name{font-size:14px;font-weight:500;margin-bottom:4px}
  .project-meta{font-family:var(--mono);font-size:10px;color:var(--muted)}
  .status-badge{font-family:var(--mono);font-size:10px;padding:3px 8px;border:1px solid var(--border)}
  .status-empty{color:var(--muted)}
  .status-raw{color:var(--blue);border-color:var(--blue)}
  .status-configured{color:#d97706;border-color:#d97706}
  .status-done{color:var(--green);border-color:var(--green)}
  .project-right{display:flex;align-items:center;gap:12px}
  .empty-state{font-family:var(--mono);font-size:11px;color:var(--muted2);text-align:center;padding:48px 0}
  .section-title{font-family:var(--mono);font-size:10px;letter-spacing:0.15em;text-transform:uppercase;color:var(--muted);margin-bottom:14px}
  .toast{position:fixed;bottom:24px;right:24px;background:var(--accent);color:#fff;font-family:var(--mono);font-size:11px;padding:10px 16px;transform:translateY(60px);opacity:0;transition:all .2s;pointer-events:none;z-index:999}
  .toast.show{transform:translateY(0);opacity:1}
</style>
</head>
<body>
<header>
  <div class="logo">RAG<span>/</span>Config</div>
  <a href="/logout" class="logout">Déconnexion</a>
</header>
<div class="main">
  <div class="page-title">Projets</div>
  <div class="page-sub">Un projet = un texte juridique. Configurez le chunking et les préfixes de contexte RAG.</div>
  <div class="new-project-box">
    <div class="section-title">Nouveau projet</div>
    <div class="row">
      <div><span class="label">Nom</span><input type="text" id="newName" placeholder="ex. Code des sociétés et associations"></div>
      <div><span class="label">Description (optionnel)</span><input type="text" id="newDesc" placeholder="ex. Version consolidée 2024"></div>
    </div>
    <button class="btn btn-primary" onclick="createProject()">Créer →</button>
  </div>
  <div class="section-title">Projets existants</div>
  <div class="project-list" id="projectList">
    {% if projects %}
      {% for p in projects %}
      <div class="project-card" onclick="window.location='/project/{{ p.id }}'">
        <div>
          <div class="project-name">{{ p.name }}</div>
          <div class="project-meta">{% if p.filename %}{{ p.filename }} · {% endif %}{% if p.stats %}{{ p.stats.total }} chunks · {% endif %}{{ p.created_at[:10] }}</div>
        </div>
        <div class="project-right">
          <span class="status-badge status-{{ p.status }}">{{ p.status }}</span>
          <button class="btn btn-danger" style="padding:4px 10px;font-size:10px" onclick="event.stopPropagation();deleteProject('{{ p.id }}',this)">✕</button>
        </div>
      </div>
      {% endfor %}
    {% else %}
      <div class="empty-state">Aucun projet. Créez-en un ci-dessus.</div>
    {% endif %}
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
function toast(msg){const t=document.getElementById('toast');t.textContent=msg;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2200);}
async function createProject(){
  const name=document.getElementById('newName').value.trim();
  const desc=document.getElementById('newDesc').value.trim();
  if(!name)return alert('Nom requis.');
  const res=await fetch('/projects',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,description:desc})});
  if(!res.ok)return alert('Erreur.');
  const proj=await res.json();
  window.location='/project/'+proj.id;
}
async function deleteProject(pid,btn){
  if(!confirm('Supprimer ce projet et toutes ses données ?'))return;
  const res=await fetch(`/projects/${pid}`,{method:'DELETE'});
  if(!res.ok)return alert('Erreur.');
  btn.closest('.project-card').remove();
  toast('Projet supprimé.');
}
</script>
</body>
</html>
EOF

cat > "$APP_DIR/templates/project.html" << 'EOFHTML'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{ project.name }} — RAG Config</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  :root{--bg:#f7f7f5;--white:#fff;--border:#e5e5e2;--border-dark:#ccc;--text:#1a1a1a;--muted:#999;--muted2:#bbb;--accent:#1a1a1a;--blue:#2563eb;--red:#dc2626;--green:#16a34a;--amber:#d97706;--mono:'DM Mono',monospace;--sans:'DM Sans',sans-serif}
  body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;font-size:14px}
  header{background:var(--white);border-bottom:1px solid var(--border);padding:0 28px;height:48px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100}
  .logo{font-family:var(--mono);font-size:12px;font-weight:500;letter-spacing:0.05em}
  .logo span{color:var(--muted)}
  .header-right{display:flex;align-items:center;gap:16px}
  .back,.logout{font-family:var(--mono);font-size:11px;color:var(--muted);text-decoration:none}
  .back:hover,.logout:hover{color:var(--text)}
  .layout{display:grid;grid-template-columns:380px 1fr;min-height:calc(100vh - 48px)}
  .panel-left{background:var(--white);border-right:1px solid var(--border);padding:24px 20px;overflow-y:auto;max-height:calc(100vh - 48px);display:flex;flex-direction:column;gap:18px}
  .panel-right{padding:28px 32px;overflow-y:auto;max-height:calc(100vh - 48px)}
  .label{font-family:var(--mono);font-size:10px;letter-spacing:0.15em;text-transform:uppercase;color:var(--muted);margin-bottom:7px;display:block}
  .section-head{font-family:var(--mono);font-size:10px;letter-spacing:0.15em;text-transform:uppercase;color:var(--muted);padding-bottom:8px;border-bottom:1px solid var(--border);margin-bottom:12px}
  input[type="text"],input[type="number"],select,textarea{width:100%;background:var(--bg);border:1px solid var(--border);color:var(--text);font-family:var(--mono);font-size:12px;padding:7px 10px;outline:none;transition:border-color .15s}
  input:focus,select:focus,textarea:focus{border-color:var(--accent)}
  .upload-zone{border:1px dashed var(--border-dark);padding:16px;text-align:center;cursor:pointer;position:relative;transition:all .15s;background:var(--bg)}
  .upload-zone:hover,.upload-zone.drag{border-color:var(--accent);background:#f0f0ee}
  .upload-zone input{position:absolute;inset:0;opacity:0;cursor:pointer;z-index:2}
  .upload-zone .hint{font-family:var(--mono);font-size:11px;color:var(--muted)}
  .upload-zone .chosen{font-family:var(--mono);font-size:10px;color:var(--green);margin-top:4px}
  .two-col{display:grid;grid-template-columns:1fr 1fr;gap:8px}
  .opt-box{background:var(--bg);border:1px solid var(--border);padding:12px;display:flex;flex-direction:column;gap:10px}
  .checkbox-row{display:flex;align-items:center;gap:8px;font-family:var(--mono);font-size:11px}
  .btn{font-family:var(--mono);font-size:11px;letter-spacing:0.1em;text-transform:uppercase;padding:8px 14px;cursor:pointer;border:1px solid var(--border);background:var(--white);color:var(--text);transition:all .15s}
  .btn:hover{border-color:var(--accent);background:var(--bg)}
  .btn-primary{width:100%;background:var(--accent);color:#fff;border-color:var(--accent);padding:10px;margin-top:4px}
  .btn-primary:hover{background:#333;border-color:#333}
  .btn-primary:disabled{opacity:.45;cursor:not-allowed}
  .btn-sm{padding:5px 10px;font-size:10px}
  .btn-danger{color:var(--red);border-color:var(--border)}
  .btn-danger:hover{border-color:var(--red);background:#fef2f2}
  .btn-blue{color:var(--blue);border-color:var(--border)}
  .btn-blue:hover{border-color:var(--blue);background:#eff6ff}
  .rules-block{background:var(--bg);border:1px solid var(--border);padding:12px}
  .rule-row{display:flex;gap:6px;margin-bottom:6px}
  .rule-row input{flex:1}
  .btn-add{width:100%;background:none;border:1px dashed var(--border-dark);color:var(--muted);font-family:var(--mono);font-size:10px;padding:6px;cursor:pointer;margin-bottom:8px;transition:all .15s}
  .btn-add:hover{border-color:var(--blue);color:var(--blue)}
  .prefix-rule-row{display:flex;gap:6px;margin-bottom:6px;align-items:center;flex-wrap:wrap}
  .prefix-rule-row .pattern{flex:1.2;min-width:120px}
  .prefix-rule-row .label-input{flex:1;min-width:100px}
  .prefix-rule-header{display:grid;grid-template-columns:1fr 1fr auto auto;gap:6px;margin-bottom:4px}
  .prefix-rule-header span{font-family:var(--mono);font-size:9px;color:var(--muted2);text-transform:uppercase;letter-spacing:0.1em}
  .test-result{background:var(--bg);border:1px solid var(--border);padding:12px;margin-top:8px;display:none}
  .test-result.open{display:block}
  .test-result-head{font-family:var(--mono);font-size:10px;color:var(--muted);margin-bottom:8px}
  .test-cols{display:grid;grid-template-columns:1fr 1fr;gap:12px}
  .test-col-title{font-family:var(--mono);font-size:9px;text-transform:uppercase;letter-spacing:0.12em;margin-bottom:6px}
  .test-col-title.match{color:var(--green)}
  .test-col-title.nomatch{color:var(--red)}
  .test-item{font-family:var(--mono);font-size:10px;padding:6px 8px;background:var(--white);border:1px solid var(--border);margin-bottom:4px;white-space:pre-wrap;word-break:break-word;max-height:80px;overflow:hidden}
  .preset-row{display:flex;gap:6px}
  .preset-row select{flex:1}
  .sep{height:1px;background:var(--border);margin:4px 0}
  .cheat-toggle{display:flex;align-items:center;gap:6px;font-family:var(--mono);font-size:10px;color:var(--blue);cursor:pointer;background:none;border:none;padding:0;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.1em}
  .cheatsheet{display:none;background:var(--bg);border:1px solid var(--border);padding:12px}
  .cheatsheet.open{display:block}
  .cheat-section-title{font-family:var(--mono);font-size:9px;letter-spacing:0.2em;text-transform:uppercase;color:var(--muted);margin-bottom:6px;margin-top:10px}
  .cheat-section-title:first-child{margin-top:0}
  .cheat-item{display:flex;align-items:flex-start;justify-content:space-between;gap:8px;padding:5px 0;border-bottom:1px solid var(--border)}
  .cheat-item:last-child{border-bottom:none}
  .cheat-code{font-family:var(--mono);font-size:10px;color:var(--text);word-break:break-all;flex:1}
  .cheat-desc{font-size:10px;color:var(--muted);white-space:nowrap}
  .cheat-add-btns{display:flex;gap:4px;flex-shrink:0}
  .cheat-add-btn{font-family:var(--mono);font-size:9px;padding:2px 6px;cursor:pointer;border:1px solid var(--border);background:var(--white);color:var(--muted);transition:all .1s;white-space:nowrap}
  .cheat-add-btn:hover{border-color:var(--blue);color:var(--blue)}
  .proj-title{font-size:16px;font-weight:500;margin-bottom:4px}
  .proj-desc{font-family:var(--mono);font-size:11px;color:var(--muted);margin-bottom:24px}
  .stats-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:20px}
  .stat-card{background:var(--white);border:1px solid var(--border);padding:12px 14px}
  .stat-val{font-family:var(--mono);font-size:20px;font-weight:500}
  .stat-label{font-family:var(--mono);font-size:10px;color:var(--muted);margin-top:2px}
  .stat-sub{font-family:var(--mono);font-size:10px;color:var(--muted2);margin-top:1px}
  .stat-warn{color:var(--amber)}
  .dist-bars{display:flex;flex-direction:column;gap:6px;margin:10px 0 20px}
  .dist-row{display:grid;grid-template-columns:80px 1fr 36px;align-items:center;gap:10px;font-family:var(--mono);font-size:11px}
  .dist-bar-wrap{height:8px;background:var(--border)}
  .dist-bar-fill{height:100%;background:var(--blue);transition:width .3s}
  .unresolved-box{background:#fffbeb;border:1px solid #fcd34d;padding:16px;margin-bottom:20px}
  .unresolved-title{font-family:var(--mono);font-size:11px;color:var(--amber);margin-bottom:12px}
  .unresolved-group{background:var(--white);border:1px solid var(--border);padding:10px 12px;margin-bottom:8px}
  .unresolved-group-meta{font-family:var(--mono);font-size:10px;color:var(--muted);margin-bottom:6px}
  .unresolved-group-preview{font-family:var(--mono);font-size:10px;white-space:pre-wrap;word-break:break-word;max-height:60px;overflow:hidden;margin-bottom:8px;opacity:.7}
  .unresolved-group-input{display:flex;gap:8px;align-items:center}
  .unresolved-group-input input{flex:1;font-size:11px}
  .unresolved-actions{display:flex;gap:8px;margin-top:12px}
  .view-toggle{display:flex;gap:0;margin-bottom:14px;border:1px solid var(--border);width:fit-content}
  .tog-btn{background:var(--white);border:none;color:var(--muted);font-family:var(--mono);font-size:10px;letter-spacing:0.1em;padding:6px 16px;cursor:pointer;text-transform:uppercase;transition:all .15s}
  .tog-btn:first-child{border-right:1px solid var(--border)}
  .tog-btn.active{background:var(--accent);color:#fff}
  .preview-tabs{display:flex;gap:4px;margin-bottom:10px;flex-wrap:wrap}
  .tab-btn{background:var(--white);border:1px solid var(--border);color:var(--muted);font-family:var(--mono);font-size:11px;padding:4px 12px;cursor:pointer;transition:all .15s}
  .tab-btn.active{background:var(--accent);color:#fff;border-color:var(--accent)}
  .chunk-card{border:1px solid var(--border);background:var(--white);display:none;padding:16px}
  .chunk-card.active{display:block}
  .chunk-meta{font-size:10px;color:var(--muted);margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid var(--border);display:flex;gap:16px;font-family:var(--mono);flex-wrap:wrap}
  .chunk-prefix{font-family:var(--mono);font-size:10px;color:var(--blue);margin-bottom:8px}
  .chunk-text{font-family:var(--mono);font-size:11px;line-height:1.7;white-space:pre-wrap;word-break:break-word}
  #rawContent{border:1px solid var(--border);background:var(--white);padding:16px;font-family:var(--mono);font-size:11px;line-height:1.7;white-space:pre-wrap;word-break:break-word;max-height:55vh;overflow-y:auto}
  .dl-row{display:flex;gap:8px;margin-top:20px;flex-wrap:wrap}
  .dl-btn{font-family:var(--mono);font-size:10px;letter-spacing:0.08em;text-decoration:none;border:1px solid var(--border);padding:7px 14px;color:var(--text);transition:all .15s}
  .dl-btn:hover{border-color:var(--accent);background:var(--bg)}
  .dl-btn.disabled{opacity:.4;pointer-events:none}
  .welcome{display:flex;align-items:center;justify-content:center;height:60vh;flex-direction:column;gap:10px;color:var(--muted2)}
  .spinner{display:inline-block;width:11px;height:11px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .6s linear infinite;vertical-align:middle;margin-right:6px}
  @keyframes spin{to{transform:rotate(360deg)}}
  .toast{position:fixed;bottom:24px;right:24px;background:var(--accent);color:#fff;font-family:var(--mono);font-size:11px;padding:10px 16px;transform:translateY(60px);opacity:0;transition:all .2s;pointer-events:none;z-index:999}
  .toast.show{transform:translateY(0);opacity:1}
  ::-webkit-scrollbar{width:4px}::-webkit-scrollbar-track{background:var(--bg)}::-webkit-scrollbar-thumb{background:var(--border-dark)}
</style>
</head>
<body>
<header>
  <div class="logo">RAG<span>/</span>Config</div>
  <div class="header-right">
    <a href="/" class="back">← Projets</a>
    <a href="/logout" class="logout">Déconnexion</a>
  </div>
</header>
<div class="layout">
  <div class="panel-left">
    <!-- 1. PDF -->
    <div>
      <div class="section-head">1 · PDF source</div>
      <div class="upload-zone" id="uploadZone">
        <input type="file" id="fileInput" accept=".pdf">
        <div class="hint">{% if project.filename %}{{ project.filename }}{% else %}Déposer un PDF ou cliquer{% endif %}</div>
        <div class="chosen" id="fileChosen"></div>
      </div>
      <div class="two-col" style="margin-top:8px">
        <div><span class="label">Page début</span><input type="number" id="pageStart" min="1" placeholder="1"></div>
        <div><span class="label">Page fin</span><input type="number" id="pageEnd" min="1" placeholder="fin"></div>
      </div>
      <button class="btn btn-primary" id="uploadBtn" onclick="uploadPdf()" style="margin-top:10px">
        {% if project.filename %}Ré-uploader{% else %}Uploader →{% endif %}
      </button>
    </div>
    <!-- 2. Options -->
    <div>
      <div class="section-head">2 · Options</div>
      <div class="opt-box">
        <div><span class="label" style="margin-bottom:5px">Taille max chunk (chars)</span><input type="number" id="maxChunkSize" value="{{ project.rules.max_size or 2500 }}" min="200"></div>
        <div class="checkbox-row"><input type="checkbox" id="addMarkers" {% if project.rules.add_markers != false %}checked{% endif %}><label for="addMarkers" style="font-family:var(--mono);font-size:11px;cursor:pointer">Marqueurs de continuité</label></div>
      </div>
    </div>
    <!-- 3. Preset -->
    <div>
      <div class="section-head">3 · Preset</div>
      <div class="preset-row">
        <select id="presetSelect" onchange="applySelectedPreset()">
          <option value="">— Personnalisé —</option>
          {% for p in presets %}<option value="{{ p.id }}">{{ p.name }}</option>{% endfor %}
        </select>
        <button class="btn btn-sm btn-danger" onclick="deleteCurrentPreset()">✕</button>
      </div>
    </div>
    <!-- 4. Règles -->
    <div>
      <div class="section-head">4 · Suppressions &amp; séparateurs</div>
      <div class="rules-block">
        <div class="label" style="margin-bottom:6px">Suppressions</div>
        <div id="removalsList"></div>
        <button class="btn-add" onclick="addRuleRow('removalsList')">+ Suppression</button>
        <div class="sep"></div>
        <div class="label" style="margin:8px 0 6px">Séparateurs de découpe</div>
        <div id="splitsList"></div>
        <button class="btn-add" onclick="addRuleRow('splitsList')">+ Séparateur</button>
      </div>
      <div style="margin-top:10px">
        <button class="cheat-toggle" onclick="toggleCheat()"><span id="cheatArrow">▶</span> Aide-mémoire regex</button>
        <div class="cheatsheet" id="cheatsheet">
          <div class="cheat-section-title">Moniteur belge</div>
          <div class="cheat-item"><div><div class="cheat-code">\n\nPage \d+ de \d+ Copyright Moniteur belge \d{2}-\d{2}-\d{4}\n\n</div><div class="cheat-desc">Pied de page</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('rem',this)">− Suppr.</button></div></div>
          <div class="cheat-item"><div><div class="cheat-code">([a-zàâéèêëîïôùûüç,])\n([a-zàâéèêëîïôùûüç])</div><div class="cheat-desc">Coupures mid-phrase</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('rem',this)">− Suppr.</button></div></div>
          <div class="cheat-section-title">Séparateurs — Codes belges</div>
          <div class="cheat-item"><div><div class="cheat-code">\n\n(Art\. \d+:\d+)</div><div class="cheat-desc">Art. X:Y — CSA, Code civil</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('spl',this)">÷ Séparer</button></div></div>
          <div class="cheat-item"><div><div class="cheat-code">\n\n(Art\. \d+)</div><div class="cheat-desc">Art. X — Code pénal, TVA…</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('spl',this)">÷ Séparer</button></div></div>
          <div class="cheat-item"><div><div class="cheat-code">\n\n(Article \d+)</div><div class="cheat-desc">Article X (forme longue)</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('spl',this)">÷ Séparer</button></div></div>
          <div class="cheat-section-title">Nettoyage général</div>
          <div class="cheat-item"><div><div class="cheat-code">\n{3,}</div><div class="cheat-desc">Sauts de ligne multiples</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('rem',this)">− Suppr.</button></div></div>
          <div class="cheat-item"><div><div class="cheat-code">^\s*\d+\s*$</div><div class="cheat-desc">Numéros de page seuls</div></div><div class="cheat-add-btns"><button class="cheat-add-btn" onclick="addCheat('rem',this)">− Suppr.</button></div></div>
        </div>
      </div>
    </div>
    <!-- 5. Préfixes -->
    <div>
      <div class="section-head">5 · Préfixes de contexte</div>
      <div class="rules-block">
        <div class="prefix-rule-header"><span>Pattern regex</span><span>Libellé</span><span></span><span></span></div>
        <div id="prefixList"></div>
        <button class="btn-add" onclick="addPrefixRow()">+ Règle de préfixe</button>
      </div>
      <div id="testResultPanel" class="test-result"></div>
    </div>
    <!-- Save + Generate -->
    <div>
      <div style="display:flex;gap:6px;margin-bottom:10px">
        <input type="text" id="newPresetName" placeholder="Nom du preset…">
        <button class="btn btn-sm" onclick="saveNewPreset()">Sauver</button>
      </div>
      <button class="btn btn-primary" id="generateBtn" onclick="generate()">Générer les chunks →</button>
      <div style="display:flex;gap:6px;margin-top:8px">
        <a href="/projects/{{ project.id }}/export-config" class="btn btn-sm" style="text-decoration:none;text-align:center;flex:1">↓ Export config</a>
      </div>
    </div>
  </div>

  <!-- PANEL DROIT -->
  <div class="panel-right">
    <div class="proj-title">{{ project.name }}</div>
    <div class="proj-desc">{% if project.description %}{{ project.description }} · {% endif %}Statut : <strong>{{ project.status }}</strong>{% if project.filename %} · {{ project.filename }}{% endif %}</div>
    <div id="welcome" class="welcome" {% if project.stats %}style="display:none"{% endif %}>
      <div style="font-size:28px;opacity:.3">⚙</div>
      <div style="font-family:var(--mono);font-size:11px">Uploadez le PDF puis générez les chunks.</div>
    </div>
    <div id="results" {% if not project.stats %}style="display:none"{% endif %}>
      <div id="unresolvedBox" style="display:none"></div>
      <div class="stats-grid">
        <div class="stat-card"><div class="stat-val" id="sTotal">{{ project.stats.total if project.stats else '—' }}</div><div class="stat-label">Chunks</div></div>
        <div class="stat-card"><div class="stat-val" id="sMax">{{ project.stats.max_size|default('—') }}</div><div class="stat-label">Max chars</div><div class="stat-sub" id="sMaxTok"></div></div>
        <div class="stat-card"><div class="stat-val" id="sAvg">{{ project.stats.avg_size|default('—') }}</div><div class="stat-label">Moy. chars</div><div class="stat-sub" id="sAvgTok"></div></div>
        <div class="stat-card"><div class="stat-val stat-warn" id="sUnresolved">{{ project.stats.unresolved|default(0) }}</div><div class="stat-label">Sans préfixe</div></div>
      </div>
      <span class="label">Distribution</span>
      <div id="distBars" class="dist-bars"></div>
      <span class="label">Aperçu</span>
      <div class="view-toggle">
        <button class="tog-btn active" id="togChunked" onclick="switchView('chunked')">Chunké</button>
        <button class="tog-btn" id="togRaw" onclick="switchView('raw')">Brut</button>
      </div>
      <div id="chunkedView"><div id="previewTabs" class="preview-tabs"></div><div id="previewCards"></div></div>
      <div id="rawView" style="display:none">
        <div style="font-family:var(--mono);font-size:10px;color:var(--muted);margin-bottom:8px">Sortie brute pymupdf4llm avant règles.</div>
        <pre id="rawContent"></pre>
      </div>
      <div class="dl-row">
        <a id="dlChunks" href="/projects/{{ project.id }}/download/chunks" class="dl-btn {% if project.status != 'done' %}disabled{% endif %}">↓ Chunks MD</a>
        <a id="dlZip"    href="/projects/{{ project.id }}/download/zip"    class="dl-btn {% if project.status != 'done' %}disabled{% endif %}">↓ ZIP chunks</a>
        <a id="dlRaw"    href="/projects/{{ project.id }}/download/raw"    class="dl-btn {% if project.status == 'empty' %}disabled{% endif %}">↓ Raw MD</a>
      </div>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script id="data-project" type="application/json">{{ project|tojson }}</script>
<script id="data-presets" type="application/json">{{ presets|tojson }}</script>
<script>
const PID="{{ project.id }}";
let project={},presets=[],rawCache=null;
try{project=JSON.parse(document.getElementById('data-project').textContent);}catch(e){}
try{presets=JSON.parse(document.getElementById('data-presets').textContent);}catch(e){}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/"/g,'&quot;');}
function toast(msg){const t=document.getElementById('toast');t.textContent=msg;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2500);}
(function initRules(){
  const r=project.rules||{};
  (r.removals||[]).forEach(v=>addRuleRow('removalsList',v));
  (r.splits||[]).forEach(v=>addRuleRow('splitsList',v));
  (r.prefix_rules||[]).forEach(pr=>addPrefixRow(pr.pattern||'',pr.label||''));
  if(r.max_size)document.getElementById('maxChunkSize').value=r.max_size;
  if(r.add_markers===false)document.getElementById('addMarkers').checked=false;
  if(project.stats)renderStats(project.stats,[]);
})();
function addRuleRow(id,val=''){
  const c=document.getElementById(id),d=document.createElement('div');
  d.className='rule-row';
  d.innerHTML=`<input type="text" value="${esc(val)}" placeholder="regex…"><button class="btn btn-sm btn-danger" onclick="this.parentElement.remove()">✕</button>`;
  c.appendChild(d);
}
function getRules(id){return Array.from(document.querySelectorAll(`#${id} input`)).map(i=>i.value.trim()).filter(Boolean);}
function addPrefixRow(pattern='',label=''){
  const c=document.getElementById('prefixList'),d=document.createElement('div');
  d.className='prefix-rule-row';
  d.innerHTML=`<input type="text" class="pattern" value="${esc(pattern)}" placeholder="ex. Art\\.\\s*5:"><input type="text" class="label-input" value="${esc(label)}" placeholder="ex. CSA — Livre 5 : SRL"><button class="btn btn-sm btn-blue" onclick="testPrefixRule(this)">Test</button><button class="btn btn-sm btn-danger" onclick="this.parentElement.remove()">✕</button>`;
  c.appendChild(d);
}
function getPrefixRules(){
  return Array.from(document.querySelectorAll('#prefixList .prefix-rule-row')).map(row=>({
    pattern:row.querySelector('.pattern').value.trim(),
    label:row.querySelector('.label-input').value.trim()
  })).filter(r=>r.pattern);
}
async function testPrefixRule(btn){
  const row=btn.closest('.prefix-rule-row');
  const pattern=row.querySelector('.pattern').value.trim();
  if(!pattern){toast('Pattern vide.');return;}
  btn.textContent='…';btn.disabled=true;
  const panel=document.getElementById('testResultPanel');
  try{
    const res=await fetch(`/projects/${PID}/test-prefix`,{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({pattern,rules:collectRules()})});
    const data=await res.json();
    if(data.error){panel.innerHTML=`<div style="color:var(--red);font-family:var(--mono);font-size:11px">${esc(data.error)}</div>`;panel.classList.add('open');return;}
    panel.classList.add('open');
    panel.innerHTML=`<div class="test-result-head">Pattern : <strong>${esc(pattern)}</strong> — ${data.match_count} match(es) sur ${data.match_count+data.no_match_count} chunks</div>
    <div class="test-cols">
      <div><div class="test-col-title match">✓ Matchent (${data.match_count}) — 5 premiers</div>${data.matches.map(m=>`<div class="test-item"><span style="color:var(--muted)">#${m.index}</span> ${esc(m.preview)}</div>`).join('')||'<div style="font-family:var(--mono);font-size:10px;color:var(--muted)">Aucun</div>'}</div>
      <div><div class="test-col-title nomatch">✗ Ne matchent pas (${data.no_match_count}) — 5 premiers</div>${data.no_matches.map(m=>`<div class="test-item"><span style="color:var(--muted)">#${m.index}</span> ${esc(m.preview)}</div>`).join('')||'<div style="font-family:var(--mono);font-size:10px;color:var(--muted)">Aucun</div>'}</div>
    </div>`;
  }catch(e){toast('Erreur : '+e.message);}
  finally{btn.textContent='Test';btn.disabled=false;}
}
function applySelectedPreset(){
  const id=document.getElementById('presetSelect').value;
  document.getElementById('removalsList').innerHTML='';document.getElementById('splitsList').innerHTML='';document.getElementById('prefixList').innerHTML='';
  const p=presets.find(x=>x.id===id);
  if(p){(p.removals||[]).forEach(r=>addRuleRow('removalsList',r));(p.splits||[]).forEach(s=>addRuleRow('splitsList',s));(p.prefix_rules||[]).forEach(pr=>addPrefixRow(pr.pattern,pr.label));}
}
async function deleteCurrentPreset(){
  const id=document.getElementById('presetSelect').value;
  if(!id||!confirm('Supprimer ce preset ?'))return;
  await fetch(`/presets/${id}`,{method:'DELETE'});location.reload();
}
async function saveNewPreset(){
  const name=document.getElementById('newPresetName').value.trim();
  if(!name)return alert('Nom requis.');
  await fetch('/presets',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({name,removals:getRules('removalsList'),splits:getRules('splitsList'),prefix_rules:getPrefixRules()})});
  location.reload();
}
async function uploadPdf(){
  const f=document.getElementById('fileInput').files[0];
  if(!f){toast('Aucun fichier sélectionné.');return;}
  const btn=document.getElementById('uploadBtn');
  btn.disabled=true;btn.innerHTML='<span class="spinner"></span>Conversion…';
  try{
    const fd=new FormData();fd.append('file',f);
    fd.append('page_start',document.getElementById('pageStart').value);
    fd.append('page_end',document.getElementById('pageEnd').value);
    const res=await fetch(`/projects/${PID}/upload`,{method:'POST',body:fd});
    if(!res.ok)throw new Error(`HTTP ${res.status}`);
    const data=await res.json();
    toast(`PDF converti — ${(data.chars/1000).toFixed(0)}k caractères bruts.`);
    document.querySelector('.upload-zone .hint').textContent=f.name;
    document.getElementById('dlRaw').classList.remove('disabled');
  }catch(e){alert('Erreur upload : '+e.message);}
  finally{btn.disabled=false;btn.innerHTML='Ré-uploader';}
}
function collectRules(){
  return{removals:getRules('removalsList'),splits:getRules('splitsList'),prefix_rules:getPrefixRules(),
    max_size:parseInt(document.getElementById('maxChunkSize').value)||2500,
    add_markers:document.getElementById('addMarkers').checked};
}
async function generate(manualLabels={},acceptUnresolved=false){
  const btn=document.getElementById('generateBtn');
  btn.disabled=true;btn.innerHTML='<span class="spinner"></span>Génération…';
  try{
    const res=await fetch(`/projects/${PID}/generate`,{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({rules:collectRules(),manual_labels:manualLabels,accept_unresolved:acceptUnresolved})});
    if(!res.ok)throw new Error(`HTTP ${res.status}`);
    const data=await res.json();
    renderStats(data.stats,data.unresolved_groups||[]);
    renderPreview(data.preview);
    document.getElementById('welcome').style.display='none';
    document.getElementById('results').style.display='block';
    if(data.done){
      toast(`${data.stats.total} chunks générés.`);
      document.getElementById('dlChunks').classList.remove('disabled');
      document.getElementById('dlZip').classList.remove('disabled');
    }
  }catch(e){alert('Erreur : '+e.message);}
  finally{btn.disabled=false;btn.innerHTML='Générer les chunks →';}
}
function renderStats(s,unresolvedGroups){
  document.getElementById('sTotal').innerText=s.total;
  document.getElementById('sMax').innerText=s.max_size.toLocaleString();document.getElementById('sMaxTok').innerText='≈ '+s.max_tokens.toLocaleString()+' tok';
  document.getElementById('sAvg').innerText=s.avg_size.toLocaleString();document.getElementById('sAvgTok').innerText='≈ '+s.avg_tokens.toLocaleString()+' tok';
  document.getElementById('sUnresolved').innerText=s.unresolved||0;
  const tot=s.total||1;
  document.getElementById('distBars').innerHTML=Object.entries(s.buckets).map(([k,v])=>{
    const pct=(v/tot*100).toFixed(1);
    return `<div class="dist-row"><div style="color:var(--muted)">${k}</div><div class="dist-bar-wrap"><div class="dist-bar-fill" style="width:${pct}%"></div></div><div style="text-align:right">${v}</div></div>`;
  }).join('');
  renderUnresolved(unresolvedGroups);
}
function renderUnresolved(groups){
  const box=document.getElementById('unresolvedBox');
  if(!groups||!groups.length){box.style.display='none';return;}
  box.style.display='block';
  box.innerHTML=`<div class="unresolved-box">
    <div class="unresolved-title">⚠ ${groups.length} plage(s) sans préfixe résolu</div>
    ${groups.map(g=>`<div class="unresolved-group">
      <div class="unresolved-group-meta">Chunks #${g.start+1} à #${g.end+1} (${g.count} chunk(s))</div>
      <div class="unresolved-group-preview">${esc(g.preview)}</div>
      <div class="unresolved-group-input">
        <input type="text" id="ml_${g.key}" placeholder="Libellé (vide = pas de préfixe)">
        <span style="font-family:var(--mono);font-size:10px;color:var(--muted)">optionnel</span>
      </div></div>`).join('')}
    <div class="unresolved-actions">
      <button class="btn btn-primary" style="width:auto" onclick="submitManualLabels()">Appliquer et finaliser →</button>
      <button class="btn btn-sm" onclick="generate({},true)">Ignorer — générer sans préfixes</button>
    </div></div>`;
}
function submitManualLabels(){
  const labels={};
  document.querySelectorAll('[id^="ml_"]').forEach(input=>{
    const key=input.id.replace('ml_','');
    const val=input.value.trim();
    const match=key.match(/group_(\d+)_(\d+)/);
    if(match){const start=parseInt(match[1]),end=parseInt(match[2]);for(let i=start;i<=end;i++)labels[`chunk_${i}`]=val;}
  });
  generate(labels,false);
}
function renderPreview(preview){
  document.getElementById('previewTabs').innerHTML=preview.map((c,i)=>
    `<button class="tab-btn ${i===0?'active':''}" onclick="switchTab(${i})">#${c.index} <span style="color:var(--muted2);font-size:9px">${c.size.toLocaleString()}c</span>${c.prefix_label?'<span style="color:var(--blue)"> ⬡</span>':''}</button>`
  ).join('');
  document.getElementById('previewCards').innerHTML=preview.map((c,i)=>
    `<div class="chunk-card ${i===0?'active':''}">
      <div class="chunk-meta"><span>Chunk #${c.index}</span><span>${c.size.toLocaleString()} chars</span><span>≈ ${c.tokens.toLocaleString()} tokens</span><span style="color:${c.resolved?'var(--green)':'var(--amber)'}">${c.resolved?(c.prefix_label?'✓ préfixé':'✓ sans préfixe'):'⚠ non résolu'}</span></div>
      ${c.prefix_label?`<div class="chunk-prefix">[${esc(c.prefix_label)}]</div>`:''}
      <div class="chunk-text">${esc(c.text)}</div>
    </div>`
  ).join('');
}
function switchTab(i){
  document.querySelectorAll('.tab-btn').forEach((b,j)=>b.classList.toggle('active',i===j));
  document.querySelectorAll('.chunk-card').forEach((c,j)=>c.classList.toggle('active',i===j));
}
async function switchView(mode){
  document.getElementById('togChunked').classList.toggle('active',mode==='chunked');
  document.getElementById('togRaw').classList.toggle('active',mode==='raw');
  document.getElementById('chunkedView').style.display=mode==='chunked'?'block':'none';
  document.getElementById('rawView').style.display=mode==='raw'?'block':'none';
  if(mode==='raw'){
    const el=document.getElementById('rawContent');
    if(!rawCache){
      el.textContent='Chargement…';
      try{const r=await fetch(`/projects/${PID}/download/raw`);rawCache=await r.text();}
      catch(e){el.textContent='Erreur.';return;}
    }
    el.textContent=rawCache;
  }
}
function toggleCheat(){const c=document.getElementById('cheatsheet'),a=document.getElementById('cheatArrow');c.classList.toggle('open');a.textContent=c.classList.contains('open')?'▼':'▶';}
function addCheat(type,btn){const code=btn.closest('.cheat-item').querySelector('.cheat-code').textContent;if(type==='rem')addRuleRow('removalsList',code);else addRuleRow('splitsList',code);toast('Ajouté.');}
document.getElementById('fileInput').addEventListener('change',e=>{const f=e.target.files[0];if(f)document.getElementById('fileChosen').innerText=f.name;});
const zone=document.getElementById('uploadZone');
zone.addEventListener('dragover',e=>{e.preventDefault();zone.classList.add('drag');});
zone.addEventListener('dragleave',()=>zone.classList.remove('drag'));
zone.addEventListener('drop',()=>zone.classList.remove('drag'));
</script>
</body>
</html>
EOFHTML

echo "=== 8. Service systemd ==="
cat > /etc/systemd/system/pdf-chunker.service << EOF
[Unit]
Description=RAG Configurator (pdf-chunker v5)
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/pdf-chunker
Environment=APP_PASSWORD=Baclain1!
Environment=SECRET_KEY=${GENERATED_KEY}
ExecStart=/opt/pdf-chunker/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8765
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== 9. Python venv ==="
if [ ! -d "$APP_DIR/venv" ]; then python3 -m venv "$APP_DIR/venv"; fi
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" -q

echo "=== 10. Redémarrage ==="
systemctl daemon-reload
systemctl enable pdf-chunker
systemctl start pdf-chunker
sleep 2

echo ""
systemctl status pdf-chunker --no-pager | head -n 15
echo ""
echo "SECRET_KEY : ${GENERATED_KEY}"
echo "=== Déploiement v5 terminé ==="
