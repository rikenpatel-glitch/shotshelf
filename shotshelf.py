#!/usr/bin/env python3
"""Shotshelf: auto-sort macOS screenshots into folders and browse them locally.

Everything runs on your Mac. Text is read with Apple's Vision framework, and
screenshots are sorted by keyword rules you can edit. No network calls.

    shotshelf.py init                 create the config file
    shotshelf.py sort                 sort new screenshots in the inbox
    shotshelf.py sort --path DIR      sort every image under DIR (backfill)
    shotshelf.py explain FILE         show why a screenshot lands where it does
    shotshelf.py index                read text of every screenshot for search
    shotshelf.py serve                start the viewer (http://127.0.0.1:8765)
    shotshelf.py install              run the watcher + viewer at login
    shotshelf.py uninstall            remove the background jobs
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP = "shotshelf"
HERE = Path(__file__).resolve().parent
OCR_BIN = HERE / "bin" / "ocr"
OCR_SRC = HERE / "ocr.swift"
STATIC = HERE / "static"
DEFAULT_RULES = HERE / "rules.default.json"
CONFIG_PATH = Path(os.environ.get("SHOTSHELF_CONFIG", Path.home() / ".config" / APP / "config.json")).expanduser()
DATA_DIR = Path.home() / "Library" / "Application Support" / "Shotshelf"
THUMB_DIR = DATA_DIR / "thumbs"

LOG_PATH = Path.home() / "Library" / "Logs" / "shotshelf.log"
AGENT_LABELS = ("com.shotshelf.watch", "com.shotshelf.serve")

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".heic", ".gif", ".webp", ".tiff", ".bmp"}
SCREENSHOT_NAME = re.compile(
    r"^(?:Screenshot|Screen Shot|CleanShot)\s+(\d{4})-(\d{2})-(\d{2})\s+at\s+(\d{1,2})[.:](\d{2})[.:](\d{2})\s*([AP]M)?",
    re.IGNORECASE,
)
MONEY = re.compile(r"[$€£₹]\s?\d[\d,]*\.\d{2}|\d[\d,]*\.\d{2}\s?(?:usd|eur|gbp|inr)", re.IGNORECASE)
PROJECT_MARKERS = (
    "package.json", ".git", "pyproject.toml", "requirements.txt", "Cargo.toml",
    "go.mod", "pubspec.yaml", "Gemfile", "pom.xml", "build.gradle", "Package.swift",
)
PROJECT_STOPWORDS = {
    "app", "apps", "src", "lib", "docs", "files", "work", "test", "tests", "demo",
    "demos", "data", "web", "site", "website", "api", "server", "client", "clients",
    "mobile", "backend", "frontend", "archive", "backups", "extra", "research",
    "scripts", "tools", "temp", "tmp", "misc", "notes", "projects", "assets",
}


def log(msg):
    line = "%s  %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)


# ---------------------------------------------------------------- config

def default_screenshot_dir():
    try:
        out = subprocess.run(
            ["defaults", "read", "com.apple.screencapture", "location"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if out:
            return out
    except Exception:
        pass
    return str(Path.home() / "Desktop")


def load_config():
    defaults = json.loads(DEFAULT_RULES.read_text())
    cfg = {
        "screenshots_dir": default_screenshot_dir(),
        "projects_dirs": [],
        "project_ignore": [],
        "port": 8765,
        "fallback": defaults["fallback"],
        "gates": defaults["gates"],
        "rules": defaults["rules"],
    }
    if CONFIG_PATH.exists():
        user = json.loads(CONFIG_PATH.read_text())
        user_rules = user.pop("rules", None)
        extra_rules = user.pop("extra_rules", [])
        cfg["gates"].update(user.pop("gates", {}))
        cfg.update(user)
        if user_rules is not None:
            cfg["rules"] = user_rules
        cfg["rules"] = extra_rules + cfg["rules"]
    cfg["root"] = Path(os.path.expanduser(cfg["screenshots_dir"])).resolve()
    return cfg


def cmd_init(_args):
    if CONFIG_PATH.exists():
        print("Config already exists: %s" % CONFIG_PATH)
        return
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    starter = {
        "screenshots_dir": default_screenshot_dir(),
        "projects_dirs": [],
        "project_ignore": [],
        "port": 8765,
        "extra_rules": [],
    }
    CONFIG_PATH.write_text(json.dumps(starter, indent=2) + "\n")
    print("Created %s" % CONFIG_PATH)
    print("Add your code folders to \"projects_dirs\" so development screenshots sort by project.")


# ---------------------------------------------------------------- database

def data_file(ext):
    """Index and lock files are per screenshots folder, so two folders never share state."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha1(str(load_config()["root"]).encode()).hexdigest()[:12]
    return DATA_DIR / ("%s.%s" % (key, ext))


def db():
    conn = sqlite3.connect(str(data_file("db")), timeout=30)
    conn.execute(
        """CREATE TABLE IF NOT EXISTS shots (
            path TEXT PRIMARY KEY,
            hash TEXT,
            text TEXT,
            folder TEXT,
            how TEXT,
            ts REAL
        )"""
    )
    conn.execute("CREATE INDEX IF NOT EXISTS shots_hash ON shots(hash)")
    return conn


def file_hash(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def shot_time(path):
    m = SCREENSHOT_NAME.match(path.name)
    if m:
        y, mo, d, hh, mm, ss, ampm = m.groups()
        hh = int(hh)
        if ampm:
            hh = hh % 12 + (12 if ampm.upper() == "PM" else 0)
        try:
            return datetime(int(y), int(mo), int(d), hh, int(mm), int(ss)).timestamp()
        except ValueError:
            pass
    st = path.stat()
    return getattr(st, "st_birthtime", st.st_mtime)


# ---------------------------------------------------------------- OCR

def ensure_ocr():
    if OCR_BIN.exists() and OCR_BIN.stat().st_mtime >= OCR_SRC.stat().st_mtime:
        return
    OCR_BIN.parent.mkdir(exist_ok=True)
    log("Compiling OCR helper (one time)...")
    subprocess.run(["swiftc", "-O", str(OCR_SRC), "-o", str(OCR_BIN)], check=True)


def ocr_batch(paths):
    if not paths:
        return {}
    ensure_ocr()
    out = subprocess.run([str(OCR_BIN)] + [str(p) for p in paths], capture_output=True, text=True)
    result = {}
    for line in out.stdout.splitlines():
        try:
            item = json.loads(line)
            result[item["path"]] = item["text"]
        except (ValueError, KeyError):
            continue
    return result


def ocr_many(paths, workers=None, chunk=12, progress=None):
    workers = workers or max(1, min(4, (os.cpu_count() or 2) // 3))
    chunks = [paths[i:i + chunk] for i in range(0, len(paths), chunk)]
    texts = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for part in pool.map(ocr_batch, chunks):
            texts.update(part)
            if progress:
                progress(len(texts), len(paths))
    return texts


def text_for(conn, path, h=None):
    """Return OCR text, reusing the cached copy when the same file was read before."""
    h = h or file_hash(path)
    row = conn.execute("SELECT text FROM shots WHERE hash=? AND text IS NOT NULL LIMIT 1", (h,)).fetchone()
    if row:
        return row[0], h
    return ocr_batch([path]).get(str(path), ""), h


# ---------------------------------------------------------------- classification

def _pattern(word):
    w = re.escape(word.lower())
    left = r"(?<![a-z0-9])" if word[:1].isalnum() else ""
    right = r"(?![a-z0-9])" if word[-1:].isalnum() else ""
    return re.compile(left + w + right)


class Classifier:
    def __init__(self, cfg):
        self.cfg = cfg
        self.root = cfg["root"]
        self.fallback = cfg["fallback"]
        self.gates = {
            name: {
                "pats": [_pattern(k) for k in g.get("keywords", [])],
                "min": g.get("min", 1),
                "money": g.get("money", False),
            }
            for name, g in cfg["gates"].items()
        }
        self.rules = []
        for r in cfg["rules"]:
            self.rules.append({
                "folder": r["folder"],
                "requires": r.get("requires"),
                "min": r.get("min_score", 2),
                "need_strong": r.get("require_strong", False),
                "unless": [_pattern(k) for k in r.get("unless", [])],
                "kw": [(k, _pattern(k)) for k in r.get("keywords", [])],
                "strong": [(k, _pattern(k)) for k in r.get("strong", [])],
                "merchants": self._merchants(r),
            })
        self.projects = self._projects()
        self.boilerplate = self._boilerplate()

    @staticmethod
    def _norm_line(line):
        return " ".join(re.sub(r"[^a-z0-9]+", " ", line.lower()).split())

    def _boilerplate(self):
        """Browser bookmark-bar lines, learned from your own screenshots.

        A line counts as bookmark-bar clutter when it repeats across many screenshots and
        almost always appears together with the browser's "Bookmarks" menu. Those lines are
        ignored when matching project and merchant names, so a bookmark called "my-project"
        doesn't pull every browser screenshot into that project, while an app's own logo
        (which also shows up outside the browser) still counts.
        """
        try:
            rows = db().execute("SELECT text FROM shots WHERE text IS NOT NULL AND text != ''").fetchall()
        except sqlite3.Error:
            return set()
        total, in_browser = {}, {}
        for (text,) in rows:
            lines = {self._norm_line(l) for l in text.splitlines()} - {""}
            browser = any("bookmarks" in l for l in lines)
            for line in lines:
                total[line] = total.get(line, 0) + 1
                if browser:
                    in_browser[line] = in_browser.get(line, 0) + 1
        threshold = max(8, int(len(rows) * 0.02))
        return {l for l, n in total.items() if n >= threshold and in_browser.get(l, 0) >= 0.9 * n}

    def _base(self, folder):
        return folder.split("/{")[0]

    def _merchants(self, rule):
        """Known merchants, plus any subfolder you created under the rule's folder."""
        if "{merchant}" not in rule["folder"]:
            return []
        names = list(rule.get("merchants", []))
        base = self.root / self._base(rule["folder"])
        if base.is_dir():
            names += [d.name for d in base.iterdir() if d.is_dir() and not d.name.startswith(".")]
        seen, out = set(), []
        for n in names:
            if n.lower() not in seen and len(n) >= 3:
                seen.add(n.lower())
                out.append((n, _pattern(n)))
        return out

    def _projects(self):
        """Project folders found in projects_dirs, matched by name in screenshot text."""
        skip = {s.lower() for s in self.cfg.get("project_ignore", [])}
        generic = PROJECT_STOPWORDS | {s.lower() for s in self.cfg.get("project_generic_names", [])}
        found = []

        def subdirs(d):
            return [c for c in sorted(d.iterdir())
                    if c.is_dir() and not c.name.startswith(".") and c.name.lower() not in skip
                    and c.name != "node_modules"]

        def is_project(d, depth=1):
            if any((d / m).exists() for m in PROJECT_MARKERS):
                return True
            return depth > 0 and any(is_project(c, depth - 1) for c in subdirs(d))

        def add(rel):
            name = rel.split("/")[-1].lower()
            variants = {name, name.replace("-", " ").replace("_", " "), name.replace("-", "").replace("_", "")}
            variants = [v for v in variants if len(v) >= 4 and v not in generic]
            if variants:
                found.append((rel, [_pattern(v) for v in variants]))

        for base in self.cfg.get("projects_dirs", []):
            base = Path(os.path.expanduser(base))
            if not base.is_dir():
                continue
            for d in subdirs(base):
                if any((d / m).exists() for m in PROJECT_MARKERS):
                    add(d.name)
                    continue
                children = [c for c in subdirs(d) if is_project(c)]
                if not children:
                    continue
                # A generic parent like "apps" or "clients" is just a shelf: use child names directly.
                group = d.name.lower() not in generic
                if group:
                    add(d.name)
                squash = lambda n: re.sub(r"[^a-z0-9]", "", n.lower())
                for c in children:
                    if group and squash(c.name) == squash(d.name):
                        continue
                    add("%s/%s" % (d.name, c.name) if group else c.name)
        dev = next((r for r in self.rules if "{project}" in r["folder"]), None)
        if dev:
            base = self.root / self._base(dev["folder"])
            if base.is_dir():
                known = {rel.lower() for rel, _ in found}
                for d in base.rglob("*"):
                    rel = str(d.relative_to(base))
                    if d.is_dir() and rel.lower() not in known and not d.name.startswith("."):
                        add(rel)
        return found

    def match_project(self, text):
        best = None
        for rel, pats in self.projects:
            hits = sum(len(p.findall(text)) for p in pats)
            if hits and (best is None or (rel.count("/"), hits) > (best[0].count("/"), best[1])):
                best = (rel, hits)
        return best if best else (None, 0)

    def classify(self, text, explain=False):
        t = " ".join(text.lower().split())
        names = " ".join(
            " ".join(x.lower().split()) for x in text.splitlines()
            if x.strip() and self._norm_line(x) not in self.boilerplate
        )
        gate_ok = {}
        for name, g in self.gates.items():
            hits = sum(1 for p in g["pats"] if p.search(t))
            gate_ok[name] = hits >= g["min"] and (not g["money"] or bool(MONEY.search(t)))
        project, project_hits = self.match_project(names)
        scored = []
        for order, r in enumerate(self.rules):
            if r["requires"] and not gate_ok.get(r["requires"]):
                continue
            hits = [k for k, p in r["kw"] if p.search(t)]
            strong = [k for k, p in r["strong"] if p.search(t)]
            if r["need_strong"] and not strong:
                continue
            if any(p.search(t) for p in r["unless"]):
                continue
            score = len(hits) + 3 * len(strong)
            if r["requires"]:
                score += 2
            folder = r["folder"]
            if "{project}" in folder:
                if project:
                    score += 5 + min(project_hits, 3)
                    folder = folder.replace("{project}", project)
                else:
                    folder = folder.replace("/{project}", "/Other")
            if "{merchant}" in folder:
                merchant = next((n for n, p in r["merchants"] if p.search(names)), None)
                if merchant:
                    score += 1
                    folder = folder.replace("{merchant}", merchant)
                else:
                    folder = folder.replace("/{merchant}", "")
            if score >= r["min"]:
                scored.append((score, -order, folder, hits + strong))
        scored.sort(reverse=True)
        choice = scored[0][2] if scored else self.fallback
        if explain:
            return choice, scored[:5], gate_ok, project
        return choice


# ---------------------------------------------------------------- moving

def unique_dest(folder, name):
    dest = folder / name
    if not dest.exists():
        return dest
    stem, ext = os.path.splitext(name)
    i = 2
    while (folder / ("%s (%d)%s" % (stem, i, ext))).exists():
        i += 1
    return folder / ("%s (%d)%s" % (stem, i, ext))


def move_file(conn, root, src, folder_rel, how, text=None, h=None):
    target = (root / folder_rel).resolve()
    if root not in target.parents and target != root:
        raise ValueError("Folder outside screenshots dir")
    target.mkdir(parents=True, exist_ok=True)
    if src.parent == target:
        dest = src
    else:
        dest = unique_dest(target, src.name)
        shutil.move(str(src), str(dest))
    rel = str(dest.relative_to(root))
    old = str(src.relative_to(root))
    row = conn.execute("SELECT hash, text, ts FROM shots WHERE path=?", (old,)).fetchone()
    if row:
        h, text, ts = h or row[0], text if text is not None else row[1], row[2]
        conn.execute("DELETE FROM shots WHERE path=?", (old,))
    else:
        ts = shot_time(dest)
    conn.execute(
        "INSERT OR REPLACE INTO shots(path, hash, text, folder, how, ts) VALUES (?,?,?,?,?,?)",
        (rel, h, text, str(Path(rel).parent) if "/" in rel else "", how, ts),
    )
    return dest


def is_image(p):
    return p.is_file() and p.suffix.lower() in IMAGE_EXTS and not p.name.startswith(".")


def cmd_sort(args):
    cfg = load_config()
    root = cfg["root"]
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(data_file("sort.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.path:
            base = Path(os.path.expanduser(args.path)).resolve()
            files = sorted(p for p in base.rglob("*") if is_image(p))
        else:
            time.sleep(1.5)
            files = sorted(p for p in root.iterdir() if is_image(p))
            files = [p for p in files if time.time() - p.stat().st_mtime > 1]
        if not files:
            return
        clf = Classifier(cfg)
        conn = db()
        hashes = {p: file_hash(p) for p in files}
        cached = {}
        for p, h in hashes.items():
            row = conn.execute("SELECT text FROM shots WHERE hash=? AND text IS NOT NULL LIMIT 1", (h,)).fetchone()
            if row:
                cached[p] = row[0]
        todo = [p for p in files if p not in cached]
        log("Sorting %d screenshot(s), %d need text recognition" % (len(files), len(todo)))
        done = [0]

        def progress(n, total):
            if total > 20 and n // 50 != done[0] // 50:
                log("  read %d/%d" % (n, total))
            done[0] = n

        texts = ocr_many(todo, progress=progress)
        counts = {}
        for p in files:
            text = cached.get(p, texts.get(str(p), ""))
            folder = clf.classify(text)
            if args.dry_run:
                counts[folder] = counts.get(folder, 0) + 1
                continue
            move_file(conn, root, p, folder, "auto", text, hashes[p])
            counts[folder] = counts.get(folder, 0) + 1
        conn.commit()
        if args.path and not args.dry_run:
            for d in sorted(base.rglob("*"), key=lambda x: -len(x.parts)):
                if d.is_dir():
                    ds = d / ".DS_Store"
                    if ds.exists() and len(list(d.iterdir())) == 1:
                        ds.unlink()
                    try:
                        d.rmdir()
                    except OSError:
                        pass
        for folder, n in sorted(counts.items(), key=lambda x: -x[1]):
            log("  %4d  %s" % (n, folder))


def cmd_explain(args):
    cfg = load_config()
    clf = Classifier(cfg)
    conn = db()
    p = Path(args.file).expanduser().resolve()
    text, _ = text_for(conn, p)
    choice, top, gates, project = clf.classify(text, explain=True)
    print("Text (first 400 chars):\n  " + " | ".join(text.splitlines())[:400])
    print("\nGates: %s" % gates)
    print("Project match: %s" % project)
    print("\nTop rules:")
    for score, _, folder, hits in top:
        print("  %3d  %-40s %s" % (score, folder, ", ".join(hits[:8])))
    print("\n-> %s" % choice)


# ---------------------------------------------------------------- index

def scan(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for f in filenames:
            p = Path(dirpath) / f
            if p.suffix.lower() in IMAGE_EXTS and not f.startswith("."):
                yield p


def reconcile(root, read_text=True, quiet=False, wait=True):
    """Bring the index in line with what is on disk (files moved in Finder, new files)."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(data_file("index.lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            return
        _reconcile(root, read_text, quiet)


def _reconcile(root, read_text, quiet):
    conn = db()
    on_disk = {str(p.relative_to(root)): p for p in scan(root)}
    known = {r[0]: r[1] for r in conn.execute("SELECT path, hash FROM shots")}
    gone = {path: h for path, h in known.items() if path not in on_disk}
    new = [p for rel, p in on_disk.items() if rel not in known]
    by_hash = {}
    for path, h in gone.items():
        by_hash.setdefault(h, path)
    need_text = []
    for p in new:
        rel = str(p.relative_to(root))
        h = file_hash(p)
        old = by_hash.pop(h, None)
        if old:
            conn.execute(
                "UPDATE shots SET path=?, folder=? WHERE path=?",
                (rel, str(Path(rel).parent) if "/" in rel else "", old),
            )
            gone.pop(old, None)
        else:
            conn.execute(
                "INSERT OR REPLACE INTO shots(path, hash, text, folder, how, ts) VALUES (?,?,NULL,?,?,?)",
                (rel, h, str(Path(rel).parent) if "/" in rel else "", "found", shot_time(p)),
            )
            need_text.append(p)
    for path in gone:
        conn.execute("DELETE FROM shots WHERE path=?", (path,))
    conn.commit()
    if read_text:
        missing = [root / r[0] for r in conn.execute("SELECT path FROM shots WHERE text IS NULL")]
        missing = [p for p in missing if p.exists()]
        if missing and not quiet:
            log("Reading text from %d screenshot(s) for search" % len(missing))
        workers = max(1, min(4, (os.cpu_count() or 2) // 3))
        for i in range(0, len(missing), workers * 8):
            part = missing[i:i + workers * 8]
            texts = ocr_many(part, workers=workers, chunk=8)
            for p in part:
                conn.execute(
                    "UPDATE shots SET text=? WHERE path=?",
                    (texts.get(str(p), ""), str(p.relative_to(root))),
                )
            conn.commit()
    conn.close()


def cmd_index(_args):
    cfg = load_config()
    reconcile(cfg["root"])
    log("Index up to date")


# ---------------------------------------------------------------- viewer

def thumb_for(path):
    st = path.stat()
    key = hashlib.sha1(("%s|%s|%s" % (path, st.st_size, st.st_mtime)).encode()).hexdigest()
    out = THUMB_DIR / (key + ".jpg")
    if not out.exists():
        THUMB_DIR.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp.jpg")
        subprocess.run(
            ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "72", "-Z", "560", str(path), "--out", str(tmp)],
            capture_output=True,
        )
        if tmp.exists():
            tmp.rename(out)
    return out


class Viewer(BaseHTTPRequestHandler):
    cfg = None
    lock = threading.Lock()

    def log_message(self, *a):
        pass

    # Only answer requests aimed at this machine, from this machine's pages.
    def _trusted(self, write=False):
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            return False
        if write and self.headers.get("X-Shotshelf") != "1":
            return False
        return True

    def _send(self, code, body, ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path, ctype, cache=True):
        data = path.read_bytes()
        self._send(200, data, ctype, {"Cache-Control": "max-age=86400" if cache else "no-cache"})

    def _resolve(self, rel):
        root = self.cfg["root"]
        p = (root / rel).resolve()
        if root not in p.parents and p != root:
            raise ValueError("bad path")
        return p

    def do_GET(self):
        if not self._trusted():
            return self._send(403, {"error": "Forbidden"})
        url = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        try:
            if url.path in ("/", "/index.html"):
                return self._file(STATIC / "index.html", "text/html; charset=utf-8", cache=False)
            if url.path == "/api/folders":
                return self._send(200, self.folders())
            if url.path == "/api/shots":
                return self._send(200, self.shots(q.get("folder", ""), q.get("q", "").strip(), q.get("deep") == "1"))
            if url.path == "/api/text":
                row = db().execute("SELECT text FROM shots WHERE path=?", (q["p"],)).fetchone()
                return self._send(200, {"text": row[0] if row and row[0] else ""})
            if url.path == "/thumb":
                return self._file(thumb_for(self._resolve(q["p"])), "image/jpeg")
            if url.path == "/file":
                p = self._resolve(q["p"])
                ctype = "image/png" if p.suffix.lower() == ".png" else "image/jpeg"
                if p.suffix.lower() in (".heic", ".tiff", ".bmp"):
                    return self._file(thumb_for(p), "image/jpeg")
                return self._file(p, ctype)
        except (KeyError, ValueError, FileNotFoundError):
            return self._send(404, {"error": "Not found"})
        self._send(404, {"error": "Not found"})

    def do_POST(self):
        if not self._trusted(write=True):
            return self._send(403, {"error": "Forbidden"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._send(400, {"error": "Bad JSON"})
        root = self.cfg["root"]
        try:
            with self.lock:
                conn = db()
                if self.path == "/api/move":
                    folder = body["folder"].strip().strip("/")
                    self._resolve(folder or ".")
                    moved = []
                    for rel in body["paths"]:
                        dest = move_file(conn, root, self._resolve(rel), folder, "manual")
                        moved.append(str(dest.relative_to(root)))
                    conn.commit()
                    return self._send(200, {"moved": moved})
                if self.path == "/api/mkdir":
                    folder = body["folder"].strip().strip("/")
                    if not folder or ".." in folder.split("/"):
                        raise ValueError("bad folder")
                    self._resolve(folder).mkdir(parents=True, exist_ok=True)
                    return self._send(200, {"ok": True})
                if self.path == "/api/trash":
                    trash = Path.home() / ".Trash"
                    for rel in body["paths"]:
                        p = self._resolve(rel)
                        shutil.move(str(p), str(unique_dest(trash, p.name)))
                        conn.execute("DELETE FROM shots WHERE path=?", (rel,))
                    conn.commit()
                    return self._send(200, {"ok": True})
                if self.path == "/api/reveal":
                    subprocess.run(["open", "-R", str(self._resolve(body["path"]))])
                    return self._send(200, {"ok": True})
                if self.path == "/api/resort":
                    clf = Classifier(self.cfg)
                    moved = []
                    for rel in body["paths"]:
                        p = self._resolve(rel)
                        text, h = text_for(conn, p)
                        dest = move_file(conn, root, p, clf.classify(text), "auto", text, h)
                        moved.append(str(dest.relative_to(root)))
                    conn.commit()
                    return self._send(200, {"moved": moved})
        except (KeyError, ValueError, FileNotFoundError) as e:
            return self._send(400, {"error": str(e)})
        self._send(404, {"error": "Not found"})

    def folders(self):
        root = self.cfg["root"]
        counts = {}
        dirs = set()
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            rel = os.path.relpath(dirpath, root)
            rel = "" if rel == "." else rel
            if rel:
                dirs.add(rel)
            counts[rel] = sum(1 for f in filenames if Path(f).suffix.lower() in IMAGE_EXTS and not f.startswith("."))
        return {
            "root": str(root),
            "fallback": self.cfg["fallback"],
            "folders": [{"path": d, "count": counts.get(d, 0)} for d in sorted(dirs, key=str.lower)],
            "inbox": counts.get("", 0),
        }

    def shots(self, folder, query, deep):
        conn = db()
        rows = []
        if query:
            like = "%" + query.replace("%", "") + "%"
            rows = conn.execute(
                "SELECT path, folder, ts FROM shots WHERE text LIKE ? OR path LIKE ? ORDER BY ts DESC LIMIT 2000",
                (like, like),
            ).fetchall()
        else:
            base = self._resolve(folder or ".")
            root = self.cfg["root"]
            meta = {r[0]: r[1] for r in conn.execute("SELECT path, ts FROM shots")}
            if deep:
                files = list(scan(base))
            else:
                files = [p for p in base.iterdir() if is_image(p)] if base.is_dir() else []
            for p in files:
                rel = str(p.relative_to(root))
                ts = meta.get(rel) or shot_time(p)
                rows.append((rel, str(Path(rel).parent) if "/" in rel else "", ts))
            rows.sort(key=lambda r: -r[2])
        return [{"p": r[0], "f": r[1], "t": r[2]} for r in rows]


def background_indexer(cfg):
    while True:
        try:
            reconcile(cfg["root"], quiet=True, wait=False)
        except Exception as e:
            log("indexer: %s" % e)
        time.sleep(300)


def cmd_serve(args):
    cfg = load_config()
    Viewer.cfg = cfg
    port = args.port or cfg.get("port", 8765)
    threading.Thread(target=background_indexer, args=(cfg,), daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", port), Viewer)
    log("Shotshelf viewer on http://127.0.0.1:%d  (screenshots: %s)" % (port, cfg["root"]))
    if args.open:
        subprocess.Popen(["open", "http://127.0.0.1:%d" % port])
    server.serve_forever()


# ---------------------------------------------------------------- launchd

def plist(label, args, extra):
    items = "".join("\n        <string>%s</string>" % a for a in args)
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>%s
    </array>
%s
    <key>StandardOutPath</key>
    <string>%s</string>
    <key>StandardErrorPath</key>
    <string>%s</string>
</dict>
</plist>
""" % (label, items, extra, LOG_PATH, LOG_PATH)


def cmd_install(_args):
    if not CONFIG_PATH.exists():
        cmd_init(None)
    cfg = load_config()
    ensure_ocr()
    cfg["root"].mkdir(parents=True, exist_ok=True)
    agents = Path.home() / "Library" / "LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    py, me = sys.executable, str(Path(__file__).resolve())
    jobs = {
        AGENT_LABELS[0]: plist(
            AGENT_LABELS[0], [py, me, "sort"],
            "    <key>WatchPaths</key>\n    <array>\n        <string>%s</string>\n    </array>\n"
            "    <key>ThrottleInterval</key>\n    <integer>3</integer>" % cfg["root"],
        ),
        AGENT_LABELS[1]: plist(
            AGENT_LABELS[1], [py, me, "serve"],
            "    <key>RunAtLoad</key>\n    <true/>\n    <key>KeepAlive</key>\n    <true/>",
        ),
    }
    uid = os.getuid()
    for label, content in jobs.items():
        path = agents / (label + ".plist")
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (uid, label)], capture_output=True)
        path.write_text(content)
        subprocess.run(["launchctl", "bootstrap", "gui/%d" % uid, str(path)], check=True)
    print("Installed. New screenshots in %s are sorted automatically." % cfg["root"])
    print("Viewer: http://127.0.0.1:%d   Log: %s" % (cfg.get("port", 8765), LOG_PATH))


def cmd_uninstall(_args):
    uid = os.getuid()
    for label in AGENT_LABELS:
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (uid, label)], capture_output=True)
        p = Path.home() / "Library" / "LaunchAgents" / (label + ".plist")
        if p.exists():
            p.unlink()
    print("Background jobs removed. Your screenshots and folders are untouched.")


def main():
    ap = argparse.ArgumentParser(prog=APP, description="Auto-sort and browse macOS screenshots.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(fn=cmd_init)
    s = sub.add_parser("sort")
    s.add_argument("--path", help="sort every image under this folder instead of the inbox")
    s.add_argument("--dry-run", action="store_true", help="show where files would go without moving them")
    s.set_defaults(fn=cmd_sort)
    e = sub.add_parser("explain")
    e.add_argument("file")
    e.set_defaults(fn=cmd_explain)
    sub.add_parser("index").set_defaults(fn=cmd_index)
    v = sub.add_parser("serve")
    v.add_argument("--port", type=int)
    v.add_argument("--open", action="store_true")
    v.set_defaults(fn=cmd_serve)
    sub.add_parser("install").set_defaults(fn=cmd_install)
    sub.add_parser("uninstall").set_defaults(fn=cmd_uninstall)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
