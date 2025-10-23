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

# ---- ENV ----
unset VIRTUAL_ENV || true
PATH="$(echo "$PATH" | awk -v RS=: -v ORS=: '($0!~/\/\.venv\// && $0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PATH
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"
export TMPDIR
export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_DEFAULT_TIMEOUT=60 PIP_PREFER_BINARY=1
# log limit mem cgroup (lebih akurat)
if [ -r /sys/fs/cgroup/memory.max ]; then kv "[CGROUP]" mem_max="$(cat /sys/fs/cgroup/memory.max)"; fi
if [ -r /sys/fs/cgroup/memory.high ]; then kv "[CGROUP]" mem_high="$(cat /sys/fs/cgroup/memory.high)"; fi
python - <<'PY'
import sys, os
print(f"[ENV] Python={sys.version.split()[0]} cwd={os.getcwd()}")
try:
    m = {k:v for k,v in (ln.split(':',1) for ln in open('/proc/meminfo') if ':' in ln)}
    print("[ENV] MemAvailable(kB)=", m.get("MemAvailable","?").strip())
except Exception as e:
    print("[ENV] Mem info n/a:", e)
PY

# ---- LOCK ----
exec 200>"$LOCKFILE"
flock -n 200 || { log "[LOCK] Another instance running -> exit"; echo "LOCKED ts=$(date -Is)" > "$STATUS_FILE"; exit 0; }
log "[LOCK] OK"

# ---- CLEAN ----
[ -d "$JOBDIR/worker/worker" ] && { rm -rf "$JOBDIR/worker/worker"; log "[CLEAN] Removed worker/worker"; }

REQ="$JOBDIR/requirements.txt"
NEED_INSTALL=0
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    NEED_INSTALL=1
    : > "$PIP_OK_FILE"
    log "[PIP] requirements changed -> wheel mode"
  else
    log "[PIP] requirements unchanged"
  fi
else
  log "[PIP] requirements.txt not found -> skip"
fi

# ---- helper: baca requirements (tanpa komentar/kosong) ----
read_requirements(){ awk '!/^\s*($|#)/{print $0}' "$REQ" | sed 's/\r$//'; }

# ---- helper: download lalu install wheel satu-per-satu ----
download_and_install(){
  local spec="$1"
  local name="$(echo "$spec" | sed 's/[<>=!~;].*$//' | tr A-Z a-z | tr '_' '-')"
  local WDIR="$JOBDIR/.wheels/$name"
  rm -rf "$WDIR"; mkdir -p "$WDIR"

  kv "[WHEEL] downloading" spec="$spec" dir="$WDIR"
  # Ambil spec + semua dependency dalam bentuk wheel
  if ! python -m pip download --only-binary=:all: -d "$WDIR" "$spec"; then
    log "[WHEEL] download FAIL for $spec"; return 1
  fi

  # install tiap wheel satu-satu (no-deps) agar tidak agregasi banyak paket dalam satu proses
  shopt -s nullglob
  # install beberapa dependency dasar dulu kalau ada
  for first in typing_extensions idna six charset_normalizer urllib3 certifi; do
    for wh in "$WDIR"/$first-*.whl; do
      kv "[WHEEL] install" file="$(basename "$wh")"
      python -m pip install --no-deps --no-compile --no-cache-dir --target "$SITEPKG" "$wh" || return 1
      rm -f "$wh"
    done
  done
  # install sisanya satu-per-satu
  for wh in "$WDIR"/*.whl; do
    kv "[WHEEL] install" file="$(basename "$wh")"
    python -m pip install --no-deps --no-compile --no-cache-dir --target "$SITEPKG" "$wh" || return 1
  done
  shopt -u nullglob
  return 0
}

install_spec(){
  local spec="$1"
  # skip jika sudah sukses sebelumnya
  if [ -s "$PIP_OK_FILE" ] && grep -Fxq "$spec" "$PIP_OK_FILE"; then
    log "[PIP] SKIP (done) $spec"; return 0; fi

  # retry 3x
  for i in 1 2 3; do
    if download_and_install "$spec"; then
      echo "$spec" >> "$PIP_OK_FILE"
      log "[PIP] OK $spec"
      return 0
    else
      kv "[PIP] FAIL" spec="$spec" attempt="$i" sleep="$((i*8))s"
      sleep $((i*8))
    fi
  done
  log "[PIP] GIVE UP $spec"
  return 1
}

# ---- INSTALL LOOP (selalu per-baris, via wheel mode) ----
if [ "$NEED_INSTALL" -eq 1 ]; then
  log "---- [STEP] Installing requirements via wheels (no multi-package install)"
  python -m pip install --upgrade pip wheel --root-user-action=ignore || true

  mapfile -t SPECS < <(read_requirements)

  total=${#SPECS[@]}
  n=0
  for spec in "${SPECS[@]}"; do
    n=$((n+1))
    log "[PIP] Installing ($n/$total): $spec"
    install_spec "$spec" || { log "[PIP] Will resume next boot"; break; }
  done

  need=$(awk '!/^\s*($|#)/{c++} END{print c+0}' "$REQ")
  donecnt=$(grep -v '^\s*$' "$PIP_OK_FILE" 2>/dev/null | wc -l | awk '{print $1}')
  kv "[PIP] progress" done="$donecnt" total="$need"

  if [ "$donecnt" -ge "$need" ]; then
    sha256sum "$REQ" | awk '{print $1}' > "$REQHASH"
    log "[PIP] All requirements installed."
  fi

  DU=$(du -sh "$SITEPKG" | awk '{print $1}')
  kv "[PIP] site-packages size" size="$DU"
fi

# ---- SANITY CHECK & LAUNCH ----
log "---- [STEP] Sanity check imports"
if python - <<'PY'
import importlib.util as iu
def chk(n):
  s=iu.find_spec(n); print(f"[CHECK] {n}: {'OK' if s else 'NOT FOUND'}", f"-> {getattr(s,'origin',None)}" if s else ""); return bool(s)
ok = chk("worker.worker") and chk("app.config")
raise SystemExit(0 if ok else 1)
PY
then
  log "[CHECK] OK"
  echo "SANITY_OK ts=$(date -Is)" > "$STATUS_FILE"
else
  log "[CHECK] FAIL -> exit"
  echo "SANITY_FAIL ts=$(date -Is)" > "$STATUS_FILE"
  exit 1
fi

echo "READY ts=$(date -Is)" > "$STATUS_FILE"
log "Launching: python -u -m worker.worker"
exec python -u -m worker.worker
