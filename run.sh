#!/usr/bin/env bash
set -Eeuo pipefail

# === Lokasi & environment ===
JOBDIR="${JOBDIR:-/home/site/wwwroot/App_Data/jobs/continuous/translator-worker}"
SITEPKG="${SITEPKG:-/home/site/wwwroot/.python_packages/lib/site-packages}"
REQFILE_DEFAULT="$JOBDIR/requirements.txt"
REQFILE_WORKER="$JOBDIR/requirements-worker.txt"   # <- pakai ini untuk worker
REQFILE="${REQFILE:-$([ -f "$REQFILE_WORKER" ] && echo "$REQFILE_WORKER" || echo "$REQFILE_DEFAULT")}"

WHEELSDIR="$JOBDIR/.wheels"
TMPDIR="/home/site/wwwroot/.tmp"
LOG="/home/LogFiles/WebJobs/translator-worker.out"

mkdir -p "$SITEPKG" "$WHEELSDIR" "$TMPDIR" "$(dirname "$LOG")"
touch "$LOG"

export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG:${PYTHONPATH:-}"
export TMPDIR
export PIP_NO_CACHE_DIR=1
export PIP_DISABLE_PIP_VERSION_CHECK=1

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" ; }

# === Fungsi kecil ===
unzip_wheel() {
  local wh="$1"
  python - <<'PY' "$wh" "$SITEPKG"
import sys, zipfile, pathlib
wh, target = sys.argv[1], sys.argv[2]
pathlib.Path(target).mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(wh) as z:
    z.extractall(target)
print(f"[UNZIP] extracted {wh} -> {target}")
PY
}

install_wheel_safe() {
  local wh="$1"
  log "[WHEEL] install $(basename "$wh")"
  if ! python -m pip install --no-deps --no-compile --no-cache-dir --target "$SITEPKG" "$wh" >>"$LOG" 2>&1; then
    log "[WHEEL] pip failed -> fallback unzip ($(basename "$wh"))"
    unzip_wheel "$wh" >>"$LOG" 2>&1 || { log "[WHEEL] unzip FAILED $(basename "$wh")"; return 1; }
  fi
}

# === Deteksi perubahan requirements ===
REQHASH_FILE="$JOBDIR/.req.hash"
if [ ! -f "$REQFILE" ]; then
  log "[PIP] requirements file not found: $REQFILE"
  exit 1
fi
NEWHASH="$(sha256sum "$REQFILE" | awk '{print $1}')"
OLDHASH="$(cat "$REQHASH_FILE" 2>/dev/null || true)"

# === Install deps jika perlu ===
if [ "$NEWHASH" != "$OLDHASH" ]; then
  log "[PIP] requirements changed -> installing from $REQFILE"
  # 1) Download semua wheel (binary only) dulu
  log "[WHEEL] downloading wheels to $WHEELSDIR"
  rm -rf "$WHEELSDIR"/* || true
  # coba beberapa kali untuk jaringan yang flakey
  n=0; until [ $n -ge 3 ]; do
    if python -m pip download --only-binary=:all: -r "$REQFILE" -d "$WHEELSDIR" >>"$LOG" 2>&1; then
      break
    fi
    n=$((n+1)); log "[WHEEL] download retry $n/3"; sleep 3
  done

  # 2) Install per wheel berdasar ukuran (kecil dulu = lebih irit memori)
  mapfile -t WHEELS < <(find "$WHEELSDIR" -type f -name '*.whl' -printf '%s\t%p\n' | sort -n | cut -f2-)
  if [ "${#WHEELS[@]}" -eq 0 ]; then
    log "[WHEEL] no wheels downloaded. Check your requirements."
  fi
  for wh in "${WHEELS[@]}"; do
    install_wheel_safe "$wh"
  done

  echo "$NEWHASH" > "$REQHASH_FILE"
  log "[PIP] DONE"
else
  log "[PIP] requirements unchanged -> skip install"
fi

# === Jalankan worker ===
cd "$JOBDIR"
log "[RUN] PYTHONPATH=$PYTHONPATH"
log "[RUN] starting: python -u -m worker.worker"
exec python -u -m worker.worker >>"$LOG" 2>&1
