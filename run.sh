#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[$(date -Is)] $*"; }
kv(){ printf "[%s] %s" "$(date -Is)" "$1"; shift; for kv in "$@"; do printf " %s" "$kv"; done; printf "\n"; }

trap 'log "[EXIT] status=$?"' EXIT
trap 'log "[ERROR] line=${LINENO} status=$?"' ERR

ROOT="/home/site/wwwroot"
JOBDIR="$ROOT/App_Data/jobs/continuous/translator-worker"
SITEPKG="$ROOT/.python_packages/lib/site-packages"
TMPDIR="$ROOT/.tmp"
LOGDIR="/home/LogFiles/WebJobs"
LOGFILE="$LOGDIR/translator-worker.out"
STATUS_FILE="$LOGDIR/translator-worker.status"
LOCKFILE="$JOBDIR/.run.lock"
REQHASH="$JOBDIR/.reqhash"
PIP_OK_FILE="$JOBDIR/.pip_ok.list"

mkdir -p "$LOGDIR" "$SITEPKG" "$TMPDIR"
cd "$JOBDIR"
exec >>"$LOGFILE" 2>&1

log "===== [BOOT] Worker starting ====="
echo "STARTING ts=$(date -Is) pid=$$" > "$STATUS_FILE"

# ---------- Env hygiene ----------
log "---- [STEP 1/7] Prepare environment"
unset VIRTUAL_ENV || true
PATH="$(echo "$PATH" | awk -v RS=: -v ORS=: '($0!~/\/\.venv\// && $0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PATH
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"
export TMPDIR
# pip tunables (hemat memori / lebih stabil)
export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_DEFAULT_TIMEOUT=60 PIP_PREFER_BINARY=1
kv "[ENV]" python="$(command -v python)" pip="$(command -v pip)" tmp="$TMPDIR"
python - <<'PY'
import sys, os, re
print(f"[ENV] Python={sys.version.split()[0]} cwd={os.getcwd()}")
print(f"[ENV] sys.path[:3]={sys.path[:3]}")
try:
    with open("/proc/meminfo") as f:
        mem = {k:int(v.split()[0]) for k,v in (ln.split(":") for ln in f if ":" in ln)}
    print("[ENV] MemAvailable(kB)=", mem.get("MemAvailable"))
except Exception as e:
    print("[ENV] Mem info n/a:", e)
PY

# ---------- Single instance ----------
log "---- [STEP 2/7] Acquire lock"
exec 200>"$LOCKFILE"
flock -n 200 || { log "[LOCK] Another instance running -> exit"; echo "LOCKED ts=$(date -Is)" > "$STATUS_FILE"; exit 0; }
log "[LOCK] OK"

# ---------- Cleanup dupe path ----------
log "---- [STEP 3/7] Cleanup duplicates"
if [ -d "$JOBDIR/worker/worker" ]; then rm -rf "$JOBDIR/worker/worker"; log "[CLEAN] Removed worker/worker"; else log "[CLEAN] Nothing to remove"; fi

# ---------- Resolve requirements changes ----------
REQ="$JOBDIR/requirements.txt"
NEED_INSTALL=0
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    NEED_INSTALL=1
    : > "$PIP_OK_FILE"  # reset progres
    log "[PIP] requirements changed -> will install"
  else
    log "[PIP] requirements unchanged"
  fi
else
  log "[PIP] requirements.txt not found -> skip"
fi

# ---------- Helpers untuk instal bertahap ----------
# ambil daftar paket (buang komentar/kosong) dan hilangkan yang sudah OK
read_requirements(){
  awk '!/^\s*($|#)/{print $0}' "$REQ" | sed 's/\r$//' | while read -r line; do
    if [ -s "$PIP_OK_FILE" ] && grep -Fxq "$line" "$PIP_OK_FILE"; then
      echo "[SKIP] $line" 1>&2
      continue
    fi
    echo "$line"
  done
}

pip_install_batch(){
  # arg: daftar paket di args
  local pkgs=("$@")
  [ ${#pkgs[@]} -eq 0 ] && return 0
  log "[PIP] Installing batch (${#pkgs[@]} pkgs) ..."
  if python -m pip install --no-cache-dir --no-compile --root-user-action=ignore --target "$SITEPKG" "${pkgs[@]}"; then
    for p in "${pkgs[@]}"; do echo "$p" >> "$PIP_OK_FILE"; done
    log "[PIP] Batch OK"
    return 0
  else
    log "[PIP] Batch FAIL"
    return 1
  fi
}

# ---------- STEP 4: Install dependencies (multi-stage) ----------
log "---- [STEP 4/7] Ensure dependencies"
if [ "$NEED_INSTALL" -eq 1 ]; then
  python -m pip install --upgrade pip wheel --root-user-action=ignore || true

  # A) coba full install sekali (hemat waktu)
  if python -m pip install --no-cache-dir --no-compile --root-user-action=ignore -r "$REQ" --target "$SITEPKG"; then
    sha256sum "$REQ" | awk '{print $1}' > "$REQHASH"
    log "[PIP] Full install OK"
  else
    log "[PIP] Full install FAIL -> fallback to chunk & per-package"

    # B) chunked install (5 per batch)
    mapfile -t ALLREQ < <(read_requirements)
    CHUNK=5
    idx=0
    total=${#ALLREQ[@]}
    while [ $idx -lt $total ]; do
      batch=("${ALLREQ[@]:$idx:$CHUNK}")
      # retry batch 3x
      ok=0
      for i in 1 2 3; do
        if pip_install_batch "${batch[@]}"; then ok=1; break; else kv "[PIP] Batch retry" attempt="$i" sleep="$((i*5))s"; sleep $((i*5)); fi
      done
      if [ $ok -ne 1 ]; then
        log "[PIP] Batch still FAIL -> switch to per-package mode for this window"
        # C) per-package with retry 3x
        for pkg in "${batch[@]}"; do
          for i in 1 2 3; do
            if python -m pip install --no-cache-dir --no-compile --root-user-action=ignore --target "$SITEPKG" "$pkg"; then
              echo "$pkg" >> "$PIP_OK_FILE"; log "[PIP] OK $pkg"; break
            else
              kv "[PIP] FAIL" pkg="$pkg" attempt="$i" sleep="$((i*7))s"
              sleep $((i*7))
            fi
          done
        done
      fi
      idx=$((idx+CHUNK))
    done

    # verifikasi akhir: coba import paket kunci
    python - <<'PY' || true
try:
  import fastapi, pydantic, requests
  print("[PIP] verify: fastapi", fastapi.__version__, "pydantic", pydantic.__version__)
except Exception as e:
  print("[PIP] verify failed:", e)
PY

    # tandai selesai jika setidaknya semua baris requirements terekam OK
    if [ "$(awk '!/^\s*($|#)/{c++} END{print c+0}' "$REQ")" -eq "$(wc -l < "$PIP_OK_FILE" 2>/dev/null || echo 0)" ]; then
      sha256sum "$REQ" | awk '{print $1}' > "$REQHASH"
      log "[PIP] Completed via fallback (chunk/per-package)"
    else
      log "[PIP] WARNING: not all requirements confirmed installed; continuing (imports will be sanity-checked)"
    fi
  fi

  DU=$(du -sh "$SITEPKG" | awk '{print $1}')
  kv "[PIP] site-packages size" size="$DU"
else
  log "[PIP] Nothing to install"
fi

# ---------- STEP 5: Sanity checks ----------
log "---- [STEP 5/7] Sanity check modules"
if python - <<'PY'
import importlib.util as iu
def chk(name):
  spec = iu.find_spec(name)
  print(f"[CHECK] {name}: {'OK' if spec else 'NOT FOUND'}", f"-> {getattr(spec,'origin',None)}" if spec else "")
  return bool(spec)
ok = chk("worker.worker") and chk("app.config")
raise SystemExit(0 if ok else 1)
PY
then
  log "[CHECK] OK (worker.worker & app.config)"
  echo "SANITY_OK ts=$(date -Is)" > "$STATUS_FILE"
else
  log "[CHECK] FAIL -> exit"
  echo "SANITY_FAIL ts=$(date -Is)" > "$STATUS_FILE"
  exit 1
fi

# ---------- STEP 6: Ready ----------
log "---- [STEP 6/7] Ready to launch"
echo "READY ts=$(date -Is)" > "$STATUS_FILE"

# ---------- STEP 7: Launch worker ----------
log "Launching: python -u -m worker.worker"
exec python -u -m worker.worker
