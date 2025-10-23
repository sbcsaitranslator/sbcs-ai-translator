#!/usr/bin/env bash
set -eEuo pipefail

log(){ echo "[$(date -Is)] $*"; }
trap 'log "EXIT status=$?"' EXIT
trap 'log "ERR line ${LINENO} status=$?"' ERR

# Path yang benar
ROOT="/home/site/wwwroot"
JOBDIR="$ROOT/App_Data/jobs/continuous/translator-worker"
SITEPKG="$ROOT/.python_packages/lib/site-packages"
LOGDIR="/home/LogFiles/WebJobs"
LOGFILE="$LOGDIR/translator-worker.out"
LOCKFILE="$ROOT/.run.lock"
REQHASH="$ROOT/.reqhash"

cd "$JOBDIR"

# Logging
mkdir -p "$LOGDIR" "$SITEPKG"
exec >>"$LOGFILE" 2>&1

log "=== WORKER STARTING ==="

# Environment
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
unset VIRTUAL_ENV || true
PATH="$(echo "$PATH" | awk -v RS=: -v ORS=: '($0!~/\/\.venv\// && $0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PATH
PYTHONPATH="${PYTHONPATH:-}"
PYTHONPATH="$(echo "$PYTHONPATH" | awk -v RS=: -v ORS=: '($0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PYTHONPATH="$SITEPKG:$ROOT:$JOBDIR"
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1

# Lock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log "Another instance running"
  exit 0
fi

# Install deps jika requirements.txt berubah
REQ="$JOBDIR/requirements.txt"
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    log "Installing requirements..."
    python -m pip install --upgrade pip wheel >/dev/null 2>&1 || true
    python -m pip install --no-cache-dir -r "$REQ" --target "$SITEPKG" --root-user-action=ignore
    echo "$CURHASH" > "$REQHASH"
    log "Installation complete"
  else
    log "Requirements unchanged"
  fi
fi

# Ensure __init__.py
touch "$JOBDIR/worker/__init__.py" "$JOBDIR/worker/__init__.py" 2>/dev/null || true

# Verify setup
python - <<'PY'
import sys, importlib.util
print("Python:", sys.version.split()[0])
print("CWD:", __import__('os').getcwd())
spec = importlib.util.find_spec("worker.worker")
if spec:
    print("✓ worker.worker found at:", spec.origin)
else:
    print("✗ worker.worker NOT FOUND")
    sys.exit(1)
PY

if [ $? -ne 0 ]; then
  log "ERROR: Module verification failed"
  exit 1
fi

# Launch worker
log "Launching worker..."
exec python -u worker/worker.py