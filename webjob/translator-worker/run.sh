#!/usr/bin/env bash
set -Eeuo pipefail

# ==== Konfigurasi path ====
JOBDIR="/home/site/wwwroot/App_Data/jobs/continuous/translator-worker"
SITEPKG="/home/site/wwwroot/.python_packages/lib/site-packages"

# ==== Env umum ====
export TZ=UTC
export PYTHONDONTWRITEBYTECODE=1
export PIP_ROOT_USER_ACTION=ignore  # redam warning pip "run as root"
export PYTHONPATH="${JOBDIR}:${SITEPKG}:${PYTHONPATH-}"

# Tangani stop dari platform dengan log rapi
trap 'echo "[$(date -u +%FT%TZ)] [INFO] SIGTERM/INT diterima, keluar..."; exit 0' INT TERM

# Identitas sumber launch (manual vs webjob)
LAUNCH_SRC="manual"
if [ -n "${WEBJOBS_NAME-}" ]; then
  LAUNCH_SRC="webjob:${WEBJOBS_NAME}"
fi

echo "[$(date -u +%FT%TZ)] [BOOT] run.sh start ($LAUNCH_SRC)"

# Pindah ke folder job
cd "$JOBDIR"

# Cek modul & sys.path
python - <<'PY'
import sys, importlib.util
print(f"[CHK] sys.path[0:3] = {sys.path[:3]}")
print(f"[CHK] worker available?  {importlib.util.find_spec('worker') is not None}")
PY

# Coba jalankan sebagai modul (hanya jika struktur modul mendukung)
echo "[$(date -u +%FT%TZ)] [RUN] starting: python -u -m worker.worker"
if python -u -m worker.worker 2>/tmp/worker_mod.err; then
  exit 0
fi

# Fallback ke file (yang memang bekerja di struktur kamu)
echo "[$(date -u +%FT%TZ)] [RUN] fallback: python -u worker/worker.py"
exec python -u worker/worker.py
