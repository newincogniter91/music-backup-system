#!/usr/bin/env python3
"""
Music Backup Server

Espone due servizi HTTP separati, su porte indipendenti:
  - servizio di backup: riceve i file audio inviati dall'app Android
    (POST /upload, campo multipart "file"), elenca i file presenti
    (GET /list) e li rende scaricabili dall'app (GET /download/<id>)
  - dashboard: pagina web con stato (ultimo backup, IP di provenienza,
    numero di file salvati) e impostazioni (cartella di salvataggio,
    indirizzo di ascolto, porte)

Funziona sia come script Python (`python3 server.py`) sia come eseguibile
compilato con PyInstaller.
"""

import asyncio
import hashlib
import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Form, Request, UploadFile, File
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse

# ---------------------------------------------------------------------------
# Percorsi base: sia in esecuzione come script sia come binario PyInstaller,
# config.json e state.json vivono accanto all'eseguibile/script stesso.
# ---------------------------------------------------------------------------
if getattr(sys, "frozen", False):
    BASE_DIR = Path(sys.executable).resolve().parent
else:
    BASE_DIR = Path(__file__).resolve().parent

CONFIG_PATH = BASE_DIR / "config.json"
STATE_PATH = BASE_DIR / "state.json"
DB_PATH = BASE_DIR / "library.db"

# Estensioni gestite: le stesse che l'app cerca sul telefono.
AUDIO_EXTENSIONS = {".mp3", ".m4a"}

DEFAULT_CONFIG = {
    "save_path": str(BASE_DIR / "musica_ricevuta"),
    "bind_host": "0.0.0.0",
    "backup_port": 47811,
    "dashboard_port": 47812,
}


def load_config():
    if CONFIG_PATH.exists():
        try:
            data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            return {**DEFAULT_CONFIG, **data}
        except (json.JSONDecodeError, OSError):
            pass
    save_config(DEFAULT_CONFIG)
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")


def load_state():
    if STATE_PATH.exists():
        try:
            return json.loads(STATE_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {"last_backup_time": None, "last_backup_ip": None}


def save_state(st):
    STATE_PATH.write_text(json.dumps(st, indent=2, ensure_ascii=False), encoding="utf-8")


config = load_config()
state = load_state()


# ---------------------------------------------------------------------------
# Database dei file presenti sul server (SQLite: incluso in Python, nessuna
# app o servizio extra; un solo file, library.db, accanto all'eseguibile).
# stored_name   = nome reale sul disco (può avere il suffisso __hash)
# original_name = nome con cui il file è arrivato dal telefono
# ---------------------------------------------------------------------------
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.execute(
    """CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        stored_name TEXT NOT NULL UNIQUE,
        original_name TEXT NOT NULL,
        size INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        added_at TEXT NOT NULL
    )"""
)
db.execute("CREATE INDEX IF NOT EXISTS idx_files_sha256 ON files(sha256)")
db.commit()


def sha256_of_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def register_file(stored_name: str, original_name: str, size: int, sha256: str):
    if Path(stored_name).suffix.lower() not in AUDIO_EXTENSIONS:
        return
    try:
        db.execute(
            "INSERT INTO files (stored_name, original_name, size, sha256, added_at) VALUES (?, ?, ?, ?, ?)",
            (stored_name, original_name, size, sha256, datetime.now().isoformat(timespec="seconds")),
        )
        db.commit()
    except sqlite3.IntegrityError:
        pass  # già registrato


def sync_db():
    """Allinea il database alla cartella di salvataggio.

    - file presenti sul disco ma non nel database (es. copiati a mano, o
      arrivati prima dell'introduzione del database) -> vengono registrati;
    - righe il cui file non esiste più (o è cambiato di dimensione) -> tolte,
      così l'app sa che quel file manca e lo rimanda.
    Non elimina mai file dal disco. L'hash si calcola solo per i file nuovi.
    """
    save_dir = Path(config["save_path"])
    if not save_dir.is_dir():
        return
    try:
        on_disk = {
            p.name: p.stat().st_size
            for p in save_dir.iterdir()
            if p.is_file() and p.suffix.lower() in AUDIO_EXTENSIONS
        }
    except OSError:
        return

    known = set()
    for row_id, stored_name, size in db.execute("SELECT id, stored_name, size FROM files").fetchall():
        if on_disk.get(stored_name) == size:
            known.add(stored_name)
        else:
            db.execute("DELETE FROM files WHERE id = ?", (row_id,))
    db.commit()

    for name, size in on_disk.items():
        if name in known:
            continue
        try:
            register_file(name, name, size, sha256_of_file(save_dir / name))
        except OSError:
            continue


sync_db()


def record_backup(request: Request):
    state["last_backup_time"] = datetime.now().isoformat(timespec="seconds")
    state["last_backup_ip"] = request.client.host if request.client else "sconosciuto"
    save_state(state)


# ---------------------------------------------------------------------------
# Servizio di backup — riceve i file dall'app.
# ---------------------------------------------------------------------------
backup_app = FastAPI()


@backup_app.get("/")
async def backup_health():
    return PlainTextResponse("Music Backup Server: servizio di upload attivo.")


@backup_app.post("/upload")
async def upload(request: Request, file: UploadFile = File(...)):
    save_dir = Path(config["save_path"])
    try:
        save_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        return JSONResponse(status_code=500, content={"status": "error", "detail": str(e)})

    content = await file.read()
    incoming_hash = hashlib.sha256(content).hexdigest()
    target_path = save_dir / file.filename

    if target_path.exists():
        try:
            existing_hash = hashlib.sha256(target_path.read_bytes()).hexdigest()
        except OSError as e:
            return JSONResponse(status_code=500, content={"status": "error", "detail": str(e)})

        if existing_hash == incoming_hash:
            # File identico già presente: non riscrivere, evita doppioni.
            register_file(target_path.name, file.filename, len(content), incoming_hash)
            record_backup(request)
            return {"status": "skipped", "reason": "duplicate", "filename": file.filename}

        # Stesso nome ma contenuto diverso: tiene entrambi, mai sovrascrive.
        disambiguator = incoming_hash[:8]
        target_path = save_dir / f"{target_path.stem}__{disambiguator}{target_path.suffix}"

    try:
        target_path.write_bytes(content)
    except OSError as e:
        return JSONResponse(status_code=500, content={"status": "error", "detail": str(e)})

    register_file(target_path.name, file.filename, len(content), incoming_hash)
    record_backup(request)
    return {"status": "saved", "filename": target_path.name}


@backup_app.get("/list")
async def list_files():
    """Elenco dei file presenti sul server (dal database)."""
    sync_db()
    rows = db.execute(
        "SELECT id, stored_name, original_name, size, sha256 FROM files ORDER BY stored_name"
    ).fetchall()
    return {
        "files": [
            {"id": r[0], "name": r[1], "original_name": r[2], "size": r[3], "sha256": r[4]}
            for r in rows
        ]
    }


@backup_app.get("/download/{file_id}")
async def download(file_id: int):
    """Scarica un file per id (l'id viene dal database, mai un percorso libero)."""
    row = db.execute("SELECT stored_name FROM files WHERE id = ?", (file_id,)).fetchone()
    if row is None:
        return JSONResponse(status_code=404, content={"status": "error", "detail": "file non trovato"})
    path = Path(config["save_path"]) / row[0]
    if not path.is_file():
        return JSONResponse(status_code=404, content={"status": "error", "detail": "file non presente su disco"})
    return FileResponse(path, filename=row[0])


# ---------------------------------------------------------------------------
# Dashboard — stato e impostazioni.
# ---------------------------------------------------------------------------
dashboard_app = FastAPI()


def render_dashboard(message: str = "") -> str:
    last_time = state.get("last_backup_time") or "Mai"
    last_ip = state.get("last_backup_ip") or "-"

    try:
        file_count = sum(1 for p in Path(config["save_path"]).glob("**/*") if p.is_file())
    except OSError:
        file_count = 0

    banner = f'<div class="banner">{message}</div>' if message else ""

    return f"""<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Music Backup — Dashboard</title>
<style>
  body {{ background:#121212; color:#eee; font-family: system-ui, sans-serif; max-width:640px; margin:40px auto; padding:0 16px; }}
  h1 {{ color:#4CAF50; }}
  h2 {{ font-size:1.05em; color:#ccc; margin-bottom:10px; }}
  .card {{ background:#1e1e1e; border-radius:8px; padding:20px; margin-bottom:20px; }}
  .banner {{ background:#4CAF50; color:#0a0a0a; padding:10px 16px; border-radius:6px; margin-bottom:20px; font-weight:bold; }}
  label {{ display:block; margin-top:14px; margin-bottom:4px; color:#aaa; font-size:0.9em; }}
  input {{ width:100%; padding:8px; border-radius:4px; border:1px solid #444; background:#2a2a2a; color:#eee; box-sizing:border-box; font-size:1em; }}
  button {{ margin-top:20px; background:#4CAF50; color:#0a0a0a; border:none; padding:10px 20px; border-radius:6px; font-weight:bold; cursor:pointer; font-size:1em; }}
  .stat {{ font-size:1.05em; margin:6px 0; }}
  .stat b {{ color:#4CAF50; }}
  .note {{ color:#888; font-size:0.85em; margin-top:12px; line-height:1.4; }}
</style>
</head>
<body>
  <h1>Music Backup</h1>
  {banner}
  <div class="card">
    <h2>Stato</h2>
    <div class="stat">Ultimo backup: <b>{last_time}</b></div>
    <div class="stat">Da IP: <b>{last_ip}</b></div>
    <div class="stat">File salvati: <b>{file_count}</b></div>
  </div>
  <div class="card">
    <h2>Impostazioni</h2>
    <form method="post" action="/settings">
      <label>Cartella di salvataggio</label>
      <input type="text" name="save_path" value="{config['save_path']}">

      <label>Indirizzo di ascolto — 0.0.0.0 per tutte le interfacce, 127.0.0.1 per solo locale, oppure un IP specifico</label>
      <input type="text" name="bind_host" value="{config['bind_host']}">

      <label>Porta servizio di backup (quella usata dall'app per inviare i file)</label>
      <input type="number" name="backup_port" value="{config['backup_port']}" min="1" max="65535">

      <label>Porta dashboard (questa pagina)</label>
      <input type="number" name="dashboard_port" value="{config['dashboard_port']}" min="1" max="65535">

      <button type="submit">Salva impostazioni</button>
      <div class="note">La cartella di salvataggio si applica subito. Indirizzo e porte richiedono un riavvio del servizio per essere applicati. La porta 80 non è ammessa (richiede permessi di amministratore).</div>
    </form>
  </div>
</body>
</html>"""


@dashboard_app.get("/", response_class=HTMLResponse)
async def dashboard():
    return render_dashboard()


@dashboard_app.post("/settings", response_class=HTMLResponse)
async def update_settings(
    save_path: str = Form(...),
    bind_host: str = Form(...),
    backup_port: int = Form(...),
    dashboard_port: int = Form(...),
):
    warnings = []

    if backup_port == 80:
        warnings.append("Porta di backup non salvata (la porta 80 richiede permessi di amministratore).")
    else:
        config["backup_port"] = backup_port

    if dashboard_port == 80:
        warnings.append("Porta dashboard non salvata (la porta 80 richiede permessi di amministratore).")
    else:
        config["dashboard_port"] = dashboard_port

    config["save_path"] = save_path
    config["bind_host"] = bind_host
    save_config(config)
    sync_db()

    if warnings:
        msg = " ".join(warnings)
    else:
        msg = "Impostazioni salvate. Riavvia il servizio se hai cambiato indirizzo o porte."
    return render_dashboard(message=msg)


# ---------------------------------------------------------------------------
# Avvio dei due servizi in parallelo sullo stesso processo.
# ---------------------------------------------------------------------------
async def main():
    print("[Music Backup Server]")
    print(f"  Backup upload:  http://{config['bind_host']}:{config['backup_port']}/upload")
    print(f"  Dashboard:      http://{config['bind_host']}:{config['dashboard_port']}/")
    print(f"  Cartella:       {config['save_path']}")

    backup_cfg = uvicorn.Config(backup_app, host=config["bind_host"], port=config["backup_port"], log_level="info")
    dashboard_cfg = uvicorn.Config(dashboard_app, host=config["bind_host"], port=config["dashboard_port"], log_level="warning")

    await asyncio.gather(
        uvicorn.Server(backup_cfg).serve(),
        uvicorn.Server(dashboard_cfg).serve(),
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except OSError as e:
        print(f"Errore all'avvio (indirizzo/porta non valida o già in uso): {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        pass
