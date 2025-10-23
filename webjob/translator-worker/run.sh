#!/usr/bin/env bash
set -Eeuo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()      { echo "[$(ts)] [INFO] $*"; }
log_run()  { echo "[$(ts)] [RUN] $*"; }
log_warn() { echo "[$(ts)] [WARN] $*"; }

# === Lokasi job & packages ===
JOBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPKG="/home/site/wwwroot/.python_packages/lib/site-packages"

# === Opsi venv (disarankan) ===
VENV_DIR="${VENV_DIR:-/home/antenv}"
USE_VENV="${USE_VENV:-1}"     # 1=pakai venv, 0=tanpa venv
SKIP_PIP="${SKIP_PIP:-1}"     # 1=skip install tiap start
REQ="${PIP_REQ_FILE:-requirements.txt}"

# === Env dasar ===
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
export PIP_ROOT_USER_ACTION=ignore
export PYTHONPATH="${JOBDIR}:${SITEPKG}:${PYTHONPATH:-}"

cd "$JOBDIR"

# Muat .env jika ada
if [[ -f ".env" ]]; then set -a; source ".env"; set +a; fi

# Virtualenv (opsional)
if [[ "$USE_VENV" = "1" ]]; then
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    log "Membuat venv di ${VENV_DIR}"
    python -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  log "VENV aktif: $(python -V)"
fi

# Install once (opsional)
if [[ "$SKIP_PIP" != "1" && -f "$REQ" ]]; then
  log "Install requirements dari ${REQ}"
  pip install --upgrade pip wheel
  pip install -r "$REQ"
fi

# === Checks (menampilkan baris [CHK] seperti contoh) ===
python - <<'PY' || true
import sys
print("[CHK] sys.path[0:3] =", sys.path[:3])
try:
    import worker
    print("[CHK] worker available? ", True)
except Exception as e:
    print("[CHK] worker import failed:", e)
PY

# === Graceful stop dari platform WebJobs ===
SHUTDOWN_FILE="${WEBJOBS_SHUTDOWN_FILE:-/tmp/WEBJOBS_SHUTDOWN_FILE}"
trap 'log "SIGTERM/INT diterima, keluar..."; exit 0' TERM INT

# === Loop jalan & auto-restart kalau crash ===
while true; do
  [[ -f "$SHUTDOWN_FILE" ]] && log "Shutdown file terdeteksi, stop." && exit 0

  # Try as module
  log_run "starting: python -u -m worker.worker"
  set +e
  python -u -m worker.worker
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    log "Proses selesai (rc=0)"
    exit 0
  fi

  # Fallback: langsung ke file
  log_run "fallback: python -u worker/worker.py"
  set +e
  python -u worker/worker.py
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    log "Fallback selesai (rc=0)"
    exit 0
  fi

  log_warn "Gagal (rc=${rc}). Retry dalam 3 detik..."
  sleep 3
done
