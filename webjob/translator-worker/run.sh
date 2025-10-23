#!/usr/bin/env bash
set -Eeuo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

# Lokasi job & site-packages
JOBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPKG="/home/site/wwwroot/.python_packages/lib/site-packages"

# (opsional) venv di /home agar persist & tanpa warning pip root
VENV_DIR="${VENV_DIR:-/home/antenv}"
USE_VENV="${USE_VENV:-1}"          # set USE_VENV=0 untuk menonaktifkan venv
SKIP_PIP="${SKIP_PIP:-0}"          # set SKIP_PIP=1 untuk skip pip install

# Env dasar
export PYTHONDONTWRITEBYTECODE=1
export PIP_ROOT_USER_ACTION=ignore
export PYTHONPATH="${JOBDIR}:${SITEPKG}:${PYTHONPATH:-}"

cd "$JOBDIR"

# Muat .env jika ada
if [[ -f ".env" ]]; then
  set -a; source ".env"; set +a
fi

# Buat/aktifkan venv (opsional)
if [[ "$USE_VENV" = "1" ]]; then
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    log "Membuat venv di ${VENV_DIR}"
    python -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  log "VENV aktif: $(python -V)"
fi

# Instal requirements (jika ada)
if [[ -f "requirements.txt" && "$SKIP_PIP" != "1" ]]; then
  log "Install requirements..."
  pip install --upgrade pip wheel
  pip install -r requirements.txt
fi

# Cek import & sys.path (debug singkat)
python - <<'PY' || true
import sys
print("[CHK] sys.path[0:3] =", sys.path[:3])
try:
    import worker
    print("[CHK] worker available? ", True)
except Exception as e:
    print("[CHK] worker import failed:", e)
PY

# Jalankan: prefer modul package (benar: titik, bukan slash)
set +e
log "[RUN] starting: python -u -m worker.worker"
python -u -m worker.worker
rc=$?
set -e

# Fallback jika -m gagal
if [[ $rc -ne 0 ]]; then
  log "[RUN] fallback: python -u worker/worker.py"
  exec python -u worker/worker.py
fi
