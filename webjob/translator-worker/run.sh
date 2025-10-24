#!/usr/bin/env bash
set -Eeuo pipefail

# ==== Path ====
ROOT="/home/site/wwwroot"
JOBDIR="$ROOT/App_Data/jobs/continuous/translator-worker"
SITEPKG="$ROOT/.python_packages/lib/site-packages"
LOCKFILE="$JOBDIR/.worker.lock"            # JANGAN pakai .run.lock (dipakai Kudu)
REQ="$JOBDIR/requirements.txt"
REQHASH="$ROOT/App_Data/.reqhash-translator-worker"
LOGDIR="/home/LogFiles/WebJobs"
LOGFILE="$LOGDIR/translator-worker.out"

# ==== Env ====
export TZ=UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_ROOT_USER_ACTION=ignore
export PYTHONPATH="$SITEPKG:$ROOT/app:$ROOT"

mkdir -p "$SITEPKG" "$LOGDIR"

trap 'echo "[$(date -u +%FT%TZ)] [INFO] SIGTERM/INT received; exiting"; exit 0' INT TERM

echo "[$(date -u +%FT%TZ)] [BOOT] run.sh start"
cd "$JOBDIR"

# ==== Single instance lock (benar) ====
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "[$(date -u +%FT%TZ)] [WARN] another instance is running; exit"
  exit 0
fi

# ==== Dependencies (install hanya saat hash berubah) ====
if [[ -f "$REQ" ]]; then
  CURHASH=$(sha256sum "$REQ" | awk '{print $1}')
  OLDHASH=$(cat "$REQHASH" 2>/dev/null || true)
  if [[ "$CURHASH" != "$OLDHASH" ]]; then
    echo "[$(date -u +%FT%TZ)] [DEPS] installing requirements..."
    # optional purge sebelum install, BUKAN setiap start
    rm -rf "$SITEPKG/azure" "$SITEPKG"/azure_*.dist-info || true
    pip install --no-cache-dir --upgrade -r "$REQ" -t "$SITEPKG"
    echo "$CURHASH" > "$REQHASH"
    echo "[$(date -u +%FT%TZ)] [DEPS] done"
  else
    echo "[$(date -u +%FT%TZ)] [DEPS] up-to-date"
  fi
fi

# ==== Cek lingkungan (pakai heredoc biar nggak hang) ====
python - <<'PY'
import sys, importlib.util
print(f"[CHK] sys.path[:3]={sys.path[:3]}")
print(f"[CHK] worker.module={bool(importlib.util.find_spec('worker'))}")
PY

# ==== Worker loop (auto restart) ====
echo "[$(date -u +%FT%TZ)] [RUN] starting worker loop"
while true; do
  # coba sebagai modul dulu, fallback ke file
  if python -u -m worker.worker >>"$LOGFILE" 2>&1; then
    echo "[$(date -u +%FT%TZ)] [INFO] worker exited 0; stop" | tee -a "$LOGFILE"
    exit 0
  fi
  rc=$?
  echo "[$(date -u +%FT%TZ)] [WARN] worker exited rc=$rc; retry in 5s" | tee -a "$LOGFILE"
  # fallback jalankan file langsung
  if python -u worker/worker.py >>"$LOGFILE" 2>&1; then
    echo "[$(date -u +%FT%TZ)] [INFO] worker.py exited 0; stop" | tee -a "$LOGFILE"
    exit 0
  fi
  rc=$?
  echo "[$(date -u +%FT%TZ)] [WARN] worker.py exited rc=$rc; retry in 5s" | tee -a "$LOGFILE"
  sleep 5
done
