#!/usr/bin/env bash
# Azure Linux WebApp Continuous WebJob bootstrap (OOM-tolerant)
# - Installs Python deps into /home/site/wwwroot/.python_packages/lib/site-packages
# - Wheel-first install with per-wheel fallback unzip (no resolver spikes)
# - Progress persists across restarts (.pip_ok.list)
# - Launches: python -u -m worker.worker

set -Eeuo pipefail

log(){ echo "[$(date -Is)] $*"; }
kv(){ printf "[%s] %s" "$(date -Is)" "$1"; shift; for pair in "$@"; do printf " %s" "$pair"; done; printf "\n"; }

trap 'log "[EXIT] status=$?"' EXIT
trap 'log "[ERROR] line=${LINENO} status=$?"' ERR

# ---- Paths & files -----------------------------------------------------------
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

# Prefer worker-specific reqs; fallback to requirements.txt
REQ="${REQ_FILE:-$JOBDIR/requirements-worker.txt}"
[ -f "$REQ" ] || REQ="$JOBDIR/requirements.txt"

# ---- Prepare fs & logging ----------------------------------------------------
mkdir -p "$LOGDIR" "$SITEPKG" "$TMPDIR" "$JOBDIR/.wheels"
cd "$JOBDIR"
# append logs
exec >>"$LOGFILE" 2>&1

log "===== [BOOT] Worker starting ====="
echo "STARTING ts=$(date -Is) pid=$$" > "$STATUS_FILE"

# ---- Environment -------------------------------------------------------------
unset VIRTUAL_ENV || true
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"
export TMPDIR
# Pip knobs to reduce RAM
export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_DEFAULT_TIMEOUT=60 PIP_PREFER_BINARY=1

# Log environment & cgroup memory limits if present
if [ -r /sys/fs/cgroup/memory.max ];  then kv "[CGROUP]" mem_max="$(cat /sys/fs/cgroup/memory.max)"; fi
if [ -r /sys/fs/cgroup/memory.high ]; then kv "[CGROUP]" mem_high="$(cat /sys/fs/cgroup/memory.high)"; fi
python - <<'PY'
import sys, os
print(f"[ENV] Python={sys.version.split()[0]} cwd={os.getcwd()}")
try:
    mem = {k:v for k,v in (ln.split(':',1) for ln in open('/proc/meminfo') if ':' in ln)}
    print("[ENV] MemAvailable(kB)=", mem.get("MemAvailable","?").strip())
except Exception as e:
    print("[ENV] Mem info n/a:", e)
PY
kv "[ENV]" python="$(command -v python)" pip="$(command -v pip)"
kv "[PIP]" requirements="${REQ}"

# ---- Single-instance lock ----------------------------------------------------
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log "[LOCK] Another instance running -> exit"
  echo "LOCKED ts=$(date -Is)" > "$STATUS_FILE"
  exit 0
fi
log "[LOCK] OK"

# ---- Cleanup duplicate layout (historical) -----------------------------------
if [ -d "$JOBDIR/worker/worker" ]; then
  rm -rf "$JOBDIR/worker/worker"
  log "[CLEAN] Removed worker/worker duplicate"
fi

# ---- Requirements change detection ------------------------------------------
NEED_INSTALL=0
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    NEED_INSTALL=1
    # IMPORTANT: do NOT clear $PIP_OK_FILE; we keep progress across restarts
    log "[PIP] requirements changed -> wheel mode (progress kept)"
  else
    log "[PIP] requirements unchanged"
  fi
else
  log "[PIP] requirements file not found -> skip installation"
fi

# ---- Helpers -----------------------------------------------------------------
memlog(){ awk '/MemAvailable/{print "[MEM]",$2" "$3}' /proc/meminfo 2>/dev/null || true; }

read_requirements(){
  # output non-empty, non-comment lines
  [ -f "$REQ" ] || return 0
  awk '!/^\s*($|#)/{print $0}' "$REQ" | sed 's/\r$//'
}

manual_install_whl() {
  # ultra-low-mem fallback: unzip wheel into site-packages
  local wh="$1" tgt="$2"
  python - "$wh" "$tgt" <<'PY'
import sys, zipfile, os
wh, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
with zipfile.ZipFile(wh) as z:
    for m in z.infolist():
        p = m.filename
        # defend against path traversal
        if ".." in p or p.startswith(("/", "\\")):
            continue
        z.extract(m, target)
print("[WHEEL] extracted ->", target)
PY
}

download_wheels_for_spec(){
  local spec="$1"
  local pkgdir="$2"
  rm -rf "$pkgdir"; mkdir -p "$pkgdir"
  kv "[WHEEL]" downloading="spec=$spec" dir="$pkgdir"
  if ! python -m pip download --only-binary=:all: -d "$pkgdir" "$spec"; then
    log "[WHEEL] download FAIL for $spec"
    return 1
  fi
  return 0
}

install_wheels_one_by_one(){
  local pkgdir="$1"
  shopt -s nullglob

  # Pre-install some common tiny deps first (often reduce import churn)
  for first in typing_extensions idna six charset_normalizer urllib3 certifi sniffio anyio; do
    for wh in "$pkgdir"/$first-*.whl; do
      local base="$(basename "$wh")"
      kv "[WHEEL] install" file="$base"
      if ! python -m pip install --no-deps --no-compile --no-cache-dir --target "$SITEPKG" "$wh"; then
        log "[WHEEL] pip install FAIL for $base -> fallback unzip"
        manual_install_whl "$wh" "$SITEPKG" || return 1
      fi
      rm -f "$wh" || true
    done
  done

  # Install remaining wheels
  for wh in "$pkgdir"/*.whl; do
    local base="$(basename "$wh")"
    kv "[WHEEL] install" file="$base"
    if ! python -m pip install --no-deps --no-compile --no-cache-dir --target "$SITEPKG" "$wh"; then
      log "[WHEEL] pip install FAIL for $base -> fallback unzip"
      manual_install_whl "$wh" "$SITEPKG" || return 1
    fi
  done

  shopt -u nullglob
  return 0
}

install_spec(){
  local spec="$1"
  # skip if already marked done
  if [ -s "$PIP_OK_FILE" ] && grep -Fxq "$spec" "$PIP_OK_FILE"; then
    log "[PIP] SKIP (done) $spec"
    return 0
  fi

  memlog
  local name="$(echo "$spec" | sed 's/[<>=!~;].*$//' | tr A-Z a-z | tr '_' '-')"
  local pkgdir="$JOBDIR/.wheels/$name"

  # retry 3x end-to-end (download+install)
  for attempt in 1 2 3; do
    if download_wheels_for_spec "$spec" "$pkgdir" && install_wheels_one_by_one "$pkgdir"; then
      echo "$spec" >> "$PIP_OK_FILE"
      log "[PIP] OK $spec"
      rm -rf "$pkgdir" || true
      return 0
    else
      kv "[PIP] FAIL" spec="$spec" attempt="$attempt" sleep="$((attempt*8))s"
      sleep $((attempt*8))
    fi
  done

  log "[PIP] GIVE UP $spec (will resume next boot)"
  return 1
}

# ---- Dependency installation (wheel mode) ------------------------------------
if [ "$NEED_INSTALL" -eq 1 ] && [ -f "$REQ" ]; then
  log "---- [STEP] Installing requirements via wheels (OOM-safe)"
  # Best effort upgrade pip/wheel (ignore failure)
  python -m pip install --upgrade pip wheel --root-user-action=ignore || true

  mapfile -t SPECS < <(read_requirements)
  total=${#SPECS[@]}
  n=0
  for spec in "${SPECS[@]}"; do
    n=$((n+1))
    log "[PIP] Installing ($n/$total): $spec"
    install_spec "$spec" || break
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

# ---- Sanity check & launch ---------------------------------------------------
log "---- [STEP] Sanity check imports"
if python - <<'PY'
import importlib.util as iu
ok = bool(iu.find_spec("worker.worker")) and bool(iu.find_spec("app.config"))
print("[CHECK] worker.worker:", "OK" if iu.find_spec("worker.worker") else "NOT FOUND")
print("[CHECK] app.config   :", "OK" if iu.find_spec("app.config") else "NOT FOUND")
raise SystemExit(0 if ok else 1)
PY
then
  log "[CHECK] OK -> launching worker"
  echo "READY ts=$(date -Is)" > "$STATUS_FILE"
else
  log "[CHECK] Not ready yet; will resume on next boot"
  echo "SANITY_PARTIAL ts=$(date -Is)" > "$STATUS_FILE"
  exit 0
fi

# Make sure module package folders exist (safe no-op if already there)
touch "$JOBDIR/worker/__init__.py" 2>/dev/null || true

# Final env hygiene (keep JOBDIR + SITEPKG ahead)
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"

log "Launching: python -u -m worker.worker"
exec python -u -m worker.worker
