#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[$(date -Is)] $*"; }
kv(){ printf "[%s] %s" "$(date -Is)" "$1"; shift; for kv in "$@"; do printf " %s" "$kv"; done; printf "\n"; }

trap 'log "[EXIT] status=$?"' EXIT
trap 'log "[ERROR] line=${LINENO} status=$?"' ERR

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

mkdir -p "$LOGDIR" "$SITEPKG" "$TMPDIR"
cd "$JOBDIR"
exec >>"$LOGFILE" 2>&1

log "===== [BOOT] Worker starting ====="
echo "STARTING ts=$(date -Is) pid=$$" > "$STATUS_FILE"

# ---------- Env hygiene ----------
unset VIRTUAL_ENV || true
PATH="$(echo "$PATH" | awk -v RS=: -v ORS=: '($0!~/\/\.venv\// && $0!~/^\/tmp\//){print}' | sed 's/:$//')"
export PATH
export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$JOBDIR:$SITEPKG${PYTHONPATH:+:$PYTHONPATH}"
export TMPDIR
# pip: hemat memori
export PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_DEFAULT_TIMEOUT=60 PIP_PREFER_BINARY=1
kv "[ENV]" python="$(command -v python)" pip="$(command -v pip)" tmp="$TMPDIR"
python - <<'PY'
import sys, os
print(f"[ENV] Python={sys.version.split()[0]} cwd={os.getcwd()}")
try:
    mem=dict(x.split(":") for x in open("/proc/meminfo") if ":" in x)
    print("[ENV] MemAvailable(kB)=", mem.get("MemAvailable","?").strip())
except Exception as e:
    print("[ENV] Mem info n/a:", e)
PY

# ---------- Single instance ----------
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log "[LOCK] Another instance running -> exit"
  echo "LOCKED ts=$(date -Is)" > "$STATUS_FILE"
  exit 0
fi
log "[LOCK] OK"

# ---------- Cleanup path dupe ----------
if [ -d "$JOBDIR/worker/worker" ]; then rm -rf "$JOBDIR/worker/worker"; log "[CLEAN] Removed worker/worker"; fi

REQ="$JOBDIR/requirements.txt"
NEED_INSTALL=0
if [ -f "$REQ" ]; then
  CURHASH="$(sha256sum "$REQ" | awk '{print $1}')"
  OLDHASH="$(cat "$REQHASH" 2>/dev/null || true)"
  if [ "$CURHASH" != "$OLDHASH" ]; then
    NEED_INSTALL=1
    : > "$PIP_OK_FILE"
    log "[PIP] requirements changed -> per-package install mode"
  else
    log "[PIP] requirements unchanged"
  fi
else
  log "[PIP] requirements.txt not found -> skip"
fi

# ---------- Helpers ----------
memlog(){ awk '/MemAvailable/{print "[MEM]",$2" "$3}' /proc/meminfo 2>/dev/null || true; }

read_requirements(){
  awk '!/^\s*($|#)/{print $0}' "$REQ" | sed 's/\r$//'
}

# urutkan: beberapa paket diprioritaskan (lebih kecil graf dependensinya)
prioritize(){
  # nama-nama tanpa versi (akan dicocokkan prefix case-insensitive)
  PRI="msrest
typing-extensions
six
idna
certifi
urllib3
charset-normalizer
anyio
httpcore
httpx
requests
isodate
cryptography
msal
msal-extensions
azure-core
azure-identity
azure-storage-blob
azure-storage-queue
pydantic
pydantic-settings
fastapi
uvicorn
gunicorn
aiohttp"
  awk 'BEGIN{IGNORECASE=1}
    NR==FNR{pri[$0]=1; order[++i]=$0; next}
    {
      line=$0; name=line;
      sub(/[<=>].*$/,"",name); gsub(/[_]/,"-",name);
      if(pri[name]) { print "P|" line; next }
      for(j=1;j<=i;j++){ if(index(tolower(name),tolower(order[j]))==1){ print "P|" line; next } }
      print "N|" line
    }' <(echo "$PRI") - \
  | sort -t'|' -k1,1r \
  | cut -d'|' -f2
}

install_one(){
  local pkg="$1"
  memlog
  for i in 1 2 3; do
    if python -m pip install --no-cache-dir --no-compile --root-user-action=ignore --target "$SITEPKG" "$pkg"; then
      echo "$pkg" >> "$PIP_OK_FILE"
      log "[PIP] OK $pkg"
      return 0
    else
      kv "[PIP] FAIL" pkg="$pkg" attempt="$i" sleep="$((i*7))s"
      sleep $((i*7))
    fi
  done
  return 1
}

# ---------- STEP: per-package install ----------
if [ "$NEED_INSTALL" -eq 1 ]; then
  log "---- [STEP] Per-package installing (no full-install to avoid OOM)"
  python -m pip install --upgrade pip wheel --root-user-action=ignore || true

  mapfile -t ALL < <(read_requirements | prioritize)

  total=${#ALL[@]}
  n=0
  for pkg in "${ALL[@]}"; do
    # skip yang sudah OK (progress survive restart)
    if [ -s "$PIP_OK_FILE" ] && grep -Fxq "$pkg" "$PIP_OK_FILE"; then
      log "[PIP] SKIP (done) $pkg"; n=$((n+1)); continue
    fi
    log "[PIP] Installing ($((n+1))/$total): $pkg"
    if ! install_one "$pkg"; then
      log "[PIP] GIVE UP on $pkg (will try next boot)"; break
    fi
    n=$((n+1))
  done

  # jika semua baris di requirements sudah masuk ke PIP_OK_FILE → tandai selesai
  need=$(awk '!/^\s*($|#)/{c++} END{print c+0}' "$REQ")
  donecnt=$(grep -v '^\s*$' "$PIP_OK_FILE" 2>/dev/null | wc -l | awk '{print $1}')
  kv "[PIP] progress" done="$donecnt" total="$need"
  if [ "$donecnt" -ge "$need" ]; then
    sha256sum "$REQ" | awk '{print $1}' > "$REQHASH"
    log "[PIP] All requirements installed."
  else
    log "[PIP] Incomplete; next restart will resume."
  fi

  DU=$(du -sh "$SITEPKG" | awk '{print $1}')
  kv "[PIP] site-packages size" size="$DU"
fi

# ---------- Sanity check ----------
log "---- [STEP] Sanity check imports"
if python - <<'PY'
import importlib.util as iu
def chk(n):
  s=iu.find_spec(n); print(f"[CHECK] {n}: {'OK' if s else 'NOT FOUND'}", f"-> {getattr(s,'origin',None)}" if s else ""); return bool(s)
ok = chk("worker.worker") and chk("app.config")
raise SystemExit(0 if ok else 1)
PY
then
  log "[CHECK] OK"
  echo "SANITY_OK ts=$(date -Is)" > "$STATUS_FILE"
else
  log "[CHECK] FAIL -> exit"
  echo "SANITY_FAIL ts=$(date -Is)" > "$STATUS_FILE"
  exit 1
fi

echo "READY ts=$(date -Is)" > "$STATUS_FILE"
log "Launching: python -u -m worker.worker"
exec python -u -m worker.worker
