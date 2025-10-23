#!/usr/bin/env bash
# run.sh — bootstrap & start translator-worker on Azure Web App (Linux)

set -Eeuo pipefail

# --- Paths (override via env if needed)
JOBDIR="${JOBDIR:-/home/site/wwwroot/App_Data/jobs/continuous/translator-worker}"
SITEPKG="${SITEPKG:-/home/site/wwwroot/.python_packages/lib/site-packages}"

# --- Pick python
if [[ -x /opt/python/3/bin/python ]]; then
  PYTHON=/opt/python/3/bin/python
elif command -v python3 >/dev/null 2>&1; then
  PYTHON=$(command -v python3)
else
  PYTHON=$(command -v python)
fi

log(){ printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" ; }

log "JOBDIR=$JOBDIR"
log "SITEPKG=$SITEPKG"
log "PYTHON=$PYTHON"

# --- Env for reliable imports & unbuffered logs
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="${JOBDIR}:${SITEPKG}:${PYTHONPATH:-}"
# (optional) quiet the root pip warning
export PIP_ROOT_USER_ACTION=ignore

# --- Go to job dir
cd "$JOBDIR"

# --- Optional install deps (skip with SKIP_PIP=1)
if [[ "${SKIP_PIP:-0}" != "1" ]]; then
  if [[ -f "$JOBDIR/requirements.txt" ]]; then
    log "Installing requirements into SITEPKG…"
    "$PYTHON" -m pip install \
      --disable-pip-version-check \
      --no-cache-dir \
      --upgrade \
      --upgrade-strategy only-if-needed \
      --target "$SITEPKG" \
      -r "$JOBDIR/requirements.txt"
  else
    log "No requirements.txt found — skipping pip install."
  fi
else
  log "SKIP_PIP=1 — skipping pip install."
fi

# --- Sanity check imports (helps diagnose path issues fast)
log "Checking module availability…"
"$PYTHON" - <<'PY' || { echo "[ERR] Import check failed"; exit 1; }
import sys, importlib.util as s
print("[CHK] sys.path[0:3] =", sys.path[0:3])
print("[CHK] has 'worker'       :", bool(s.find_spec("worker")))
print("[CHK] has 'worker.worker':", bool(s.find_spec("worker.worker")))
PY

# --- Graceful shutdown
_term(){ log "Signal caught, stopping…"; kill -TERM "${child:-0}" 2>/dev/null || true; wait "${child:-0}" 2>/dev/null || true; }
trap _term INT TERM

# --- Start the worker (as a module). Fallback to file-path if needed.
log "Starting: python -u -m worker.worker"
set +e
"$PYTHON" -u -m worker.worker "$@" &
child=$!
wait $child
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "Module launch failed (rc=$rc). Falling back: python -u worker/worker.py"
  exec "$PYTHON" -u "$JOBDIR/worker/worker.py" "$@"
else
  exit 0
fi
