#!/usr/bin/env bash
set -Eeuo pipefail

# ====== Konfigurasi path ======
JOBDIR="/home/site/wwwroot/App_Data/jobs/continuous/translator-worker"
SITEPKG_ROOT="/home/site/wwwroot/.python_packages"
SITEPKG="$SITEPKG_ROOT/lib/site-packages"
LOG="/home/LogFiles/WebJobs/translator-worker.out"
REQFILE="$JOBDIR/requirements.txt"  # khusus worker

# ====== Env hemat IO/mem ======
export PIP_NO_CACHE_DIR=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PYTHONPATH="$JOBDIR:$SITEPKG:${PYTHONPATH:-}"

# ====== Helper logging ======
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo "[$(_ts)] $*" | tee -a "$LOG"; }

# ====== Bersih sisa proses/install ======
pkill -f "python -u -m worker" 2>/dev/null || true
pkill -f "pip " 2>/dev/null || true

mkdir -p "$SITEPKG" "$(dirname "$LOG")"
: > "$LOG"

log "===== [BOOT] Worker starting ====="
log "[ENV] Python=$(python -V 2>&1) cwd=$JOBDIR"
log "[ENV] PYTHONPATH=$PYTHONPATH"

# ====== Install requirements worker ======
if [[ -s "$REQFILE" ]]; then
  log "[PIP] Installing worker requirements from $REQFILE"
  python -m pip install --upgrade pip wheel >>"$LOG" 2>&1
  python -m pip install --no-compile --no-cache-dir -t "$SITEPKG" -r "$REQFILE" >>"$LOG" 2>&1
else
  log "[PIP] WARNING: $REQFILE not found or empty; skip install"
fi

# ====== Sanity check import ======
python - <<'PY' 2>>"$LOG" | tee -a "$LOG"
import sys, pkgutil
print("[CHK] sys.path[0:3] =", sys.path[:3])
print("[CHK] worker available? ", bool(pkgutil.find_loader("worker")))
PY

# ====== Start worker ======
cd "$JOBDIR"

# Opsi A (lebih sederhana & aman): jalankan paket top-level 'worker'
CMD=(python -u -m worker.worker)


log "[RUN] starting: ${CMD[*]}"
# jalankan di foreground supaya WebJob menganggap proses ini 'running'
exec "${CMD[@]}" >>"$LOG" 2>&1
