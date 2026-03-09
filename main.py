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
