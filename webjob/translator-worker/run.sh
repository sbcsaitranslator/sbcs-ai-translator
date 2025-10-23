#!/usr/bin/env bash
set -Eeuo pipefail

# =========[ Logging Utils ]=========
log(){ echo "[$(date -Is)] $*"; }
kv(){  # log key=value pairs di satu baris
  local msg="$1"; shift
  printf "[%s] %s" "$(date -Is)" "$msg"
  for kv in "$@"; do printf " %s" "$kv"; done
  printf "\n"
}

trap 'log "[EXIT] status=$?"' EXIT
trap 'log "[ERROR] line=${LINENO} status=$?"' ERR

# =========[ Paths ]=========
ROOT="/home/site/wwwroot"
JOBDIR="$ROOT/App_Data/jobs/continuous/translator-worker"
SITEPKG="$ROOT/.python_packages/lib/site-packages"
LOGDIR="/home/LogFiles/WebJobs"
LOGFILE="$LOGDIR/translator-worker.out"
LOCKFILE="$JOBDIR/.run.lock"
REQHASH="$JOBDIR/.reqhash"
STATUS_FILE="$LOGDIR/translator-worker.status"
START_TS="$(date +%s)"

mkdir -p "$LOGDIR" "$SITEPKG"
cd "$JOBDIR"
# arahkan stdout+stderr ke file log App Service
exec >>"$LOGFILE" 2>&1

log "===== [BOOT] Worker starting ====="
kv  "[BOOT]" site_name="$WEBSITE_SITE_NAME" plan="AppService" os="$(uname -a)"
kv  "[BOOT]" jobdir="$JOBDIR" sitepkgs="$SITEPKG" log="$LOGFILE"

echo "STARTING ts=$(date -Is) pid=$$" > "$STATUS_FILE"

# =========[ STEP 1: Env Hygiene ]=========
log "---- [STEP 1/6] Prepare environment"
unset VIRTUAL_ENV || true
PATH="$(echo "$PATH" | awk -v RS=: -v ORS=: '($0!~/\/\.venv\// && $0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PATH
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"
kv  "[ENV]" python="$(command -v python)" pip="$(command -v pip)"
python - <<'PY'
import sys, os
print(f"[ENV] Python={sys.version.split()[0]} cwd={os.getcwd()}")
print(f"[ENV] sys.path[0:3]={sys.path[:3]}")
PY

# =========[ STEP 2: Single-instance Lock ]=========
log "---- [STEP 2/6] Acquire lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log "[LOCK] Another instance is running -> EXIT"
  echo "LOCKED ts=$(date -Is)" > "$STATUS_FILE"
  exit 0
fi
log "[LOCK] OK"

# =========[ STEP 3: Cleanup duplikasi paket ]=========
log "---- [STEP 3/6] Cleanup duplicates"
if [ -d "$JOBDIR/worker/worker" ]; then
  rm -rf "$JOBDIR/worker/worker"
  log "[CLEAN] Removed: worker/worker"
else
  log "[CLEAN] Nothing to remove"
fi

# =========[ STEP 4: Install Dependencies (on change) ]=========
log "---- [STEP 4/6] Ensure dependencies"
REQ="$JOBDIR/requirements.txt"
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    log "[PIP] requirements changed -> installing to $SITEPKG"
    python -m pip install --upgrade pip wheel --root-user-action=ignore || true
    for i in 1 2 3; do
      if python -m pip install --no-cache-dir -r "$REQ" --target "$SITEPKG" --root-user-action=ignore; then
        echo "$CURHASH" > "$REQHASH"
        DU=$(du -sh "$SITEPKG" | awk '{print $1}')
        kv "[PIP] OK" attempts="$i" sitepkgs_size="$DU"
        break
      else
        kv "[PIP] FAIL" attempt="$i" sleep="$((i*5))s"
        sleep $((i*5))
      fi
    done
  else
    log "[PIP] requirements unchanged -> skip"
  fi
else
  log "[PIP] requirements.txt not found -> skip"
fi

# ringkas daftar paket kunci (jika ada)
python - <<'PY' || true
try:
  import pkg_resources as pr
  wanted = {"fastapi","uvicorn","pydantic","azure-storage-blob","azure-identity","aiohttp","requests"}
  installed = {d.project_name.lower(): d.version for d in pr.working_set if d.project_name}
  found = {k:installed.get(k) for k in sorted(wanted)}
  print("[PIP] key-packages:", {k:v for k,v in found.items() if v})
except Exception as e:
  print("[PIP] key-packages: n/a", e)
PY

# =========[ STEP 5: Sanity Check Imports ]=========
log "---- [STEP 5/6] Sanity check modules"
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
  log "[CHECK] OK (worker.worker & app.config found)"
  echo "SANITY_OK ts=$(date -Is)" > "$STATUS_FILE"
else
  log "[CHECK] FAIL (module not found)"
  echo "SANITY_FAIL ts=$(date -Is)" > "$STATUS_FILE"
  exit 1
fi

# =========[ STEP 6: Launch Worker (module mode) ]=========
ELAPSED=$(( $(date +%s) - START_TS ))
kv  "[READY]" action="launch" cmd="python -u -m worker.worker" elapsed_s="$ELAPSED"
echo "READY ts=$(date -Is) elapsed=${ELAPSED}s" > "$STATUS_FILE"

# Catatan: exec akan menggantikan shell -> proses worker menjadi PID ini
exec python -u -m worker.worker
