#!/usr/bin/env bash
# render-pod.sh — siklus render Remotion di pod RunPod dengan template
# "Remotion GPU - image sendiri" (2r4zu7wvgp), lalu pod dihapus sendiri.
#
# Semua nilai di bawah ini SUDAH TERUJI di pod nyata (21 Nov 2026), bukan tebakan:
#   - pod A40 secure, `--wait --wait-for ssh` siap ~15 detik
#   - render 900 frame 1920x1080 = 57 detik di pod
#   - pod wajib dihapus di akhir; `pod list` harus kosong
#
# Pemakaian:
#   render-pod.sh <direktori-proyek> <entry> <komposisi>
#   render-pod.sh ~/workspace/projects/skala-alam-semesta src/index.tsx SkalaLangit
#
# Hasil: <proyek>/out-pod/<komposisi>-<tanggal>.mp4 + log di out-pod/render-pod.log
#
# Env opsional:
#   TEMPLATE_ID   default 2r4zu7wvgp
#   GPU           daftar GPU dipisah koma, DICOBA BERURUTAN sesuai prioritas
#                 (default: dari yang paling murah, lihat DEFAULT_GPU di bawah)
#   DATA_CENTER   default EU-RO-1 (lokasi network volume; pod harus se-DC dengan volume)
#   GPU_CADANGAN  ditambahkan SESUDAH daftar GPU kalau semua di GPU gagal
#   CLOUD         SECURE | COMMUNITY     (default SECURE)
#   TARUH_VOLUME  id network volume untuk cache node_modules (opsional).
#                 Volume ter-mount di /workspace bawaan RunPod. Jangan ubah ke
#                 /workspace/remotion-app: itu menutupi ekosistem bawaan image.
#   HAPUS_POD     1 (default) | 0 kalau mau menyimpan pod untuk debug
set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"

PROYEK=${1:?pakai: render-pod.sh <direktori-proyek> <entry> <komposisi>}
ENTRY=${2:?entry, mis. src/index.tsx}
KOMPOSISI=${3:?komposisi, mis. MainComp}
PROYEK=$(cd "$PROYEK" && pwd)

TEMPLATE_ID=${TEMPLATE_ID:-2r4zu7wvgp}
# Urutan bawaan = dari yang paling murah menurut harga GLOBAL (secure, 22 Nov 2026:
# A40 $0,59 · L4 $0,69 · 4090 $0,89 · L40S $1,09 · RTX 6000 Ada $1,09).
# Dengan TARUH_VOLUME (EU-RO-1) harga per GPU beda — urutan lokal ada di panduan bagian 3.
DEFAULT_GPU="NVIDIA GeForce RTX 4090,NVIDIA A40,NVIDIA L4,NVIDIA RTX 6000 Ada Generation,NVIDIA L40S"
GPU=${GPU:-"$DEFAULT_GPU"}
DATA_CENTER=${DATA_CENTER:-EU-RO-1}
GPU_CADANGAN=${GPU_CADANGAN:-""}
CLOUD=${CLOUD:-SECURE}
HAPUS_POD=${HAPUS_POD:-1}
KUNCI="$HOME/.runpod/ssh/runpodctl-ssh-key"

NAMA="rk-$(basename "$PROYEK" | tr -cs 'a-z0-9' '-' | cut -c1-20)-$(date +%m%d%H%M)"
KELUARAN_DIR="$PROYEK/out-pod"
LOG="$KELUARAN_DIR/render-pod.log"
mkdir -p "$KELUARAN_DIR"

catat() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# --- bersih-bersih: pod dibuat skrip ini harus hilang, apa pun yang terjadi ---
POD_ID=""
bersihkan() {
  local kode=$?
  if [ -n "$POD_ID" ] && [ "$HAPUS_POD" = "1" ]; then
    catat "membersihkan pod $POD_ID"
    runpodctl pod stop "$POD_ID" >/dev/null 2>&1 || true
    sleep 10
    runpodctl pod delete "$POD_ID" >/dev/null 2>&1 || true
    sleep 5
    if runpodctl pod get "$POD_ID" >/dev/null 2>&1; then
      catat "GAGAL menghapus pod $POD_ID — hapus manual sekarang: runpodctl pod delete $POD_ID"
    else
      catat "pod $POD_ID sudah tidak ada"
    fi
  elif [ -n "$POD_ID" ]; then
    catat "pod $POD_ID DIBIARKAN HIDUP (HAPUS_POD=0) — hentikan manual kalau sudah selesai"
  fi
  exit "$kode"
}
trap bersihkan EXIT INT TERM

# --- pra-cek di sisi lokal: gagal cepat sebelum menyewa GPU ---
# Jangan biarkan trap bersih-bersih mengubah exit code karena POD_ID kosong.
catat "proyek: $PROYEK (entry $ENTRY, komposisi $KOMPOSISI)" 2>/dev/null || true
test -f "$PROYEK/$ENTRY" || { catat "entry tidak ada: $PROYEK/$ENTRY"; exit 2; }
test -f "$KUNCI" || { catat "kunci SSH tidak ada di $KUNCI (jalankan: runpodctl doctor)"; exit 2; }
df -h "$PROYEK" | tail -1 | tee -a "$LOG"

# --- 1. buat pod ---
# Volume network hanya bisa dipakai pod di data center yang sama, jadi
# DATA_CENTER dipaksa sejalan begitu TARUH_VOLUME diisi.
ARG_VOL=()
if [ -n "${TARUH_VOLUME:-}" ]; then
  ARG_VOL=(--network-volume-id "$TARUH_VOLUME" --data-center-ids "$DATA_CENTER")
  catat "volume cache $TARUH_VOLUME dipasang di $DATA_CENTER"
fi

BISA=0
# GPU (urutan prioritas) lalu GPU_CADANGAN (cadangan terakhir). Harga tidak
# disortir otomatis, jadi urutan daftar = urutan prioritas yang disengaja.
# Daftar dibaca BARIS PER BARIS: satu GPU per entri, spasi di dalam nama GPU aman.
# Dulu pakai `tr ',' ' '` + for, sehingga "NVIDIA GeForce RTX 4090" pecah jadi 4 GPU.
GPU_SEMUA=$(printf '%s\n%s\n' "$GPU" "$GPU_CADANGAN" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')
URUTAN_TAMPIL=$(printf '%s' "$GPU_SEMUA" | paste -sd '>' -)
catat "membuat pod dari template $TEMPLATE_ID di $DATA_CENTER (urutan GPU: $URUTAN_TAMPIL | cloud $CLOUD)"
while IFS= read -r G; do
  LOG_POD="$KELUARAN_DIR/pod-$G.log"
  # Catatan: dengan --wait, runpodctl menulis progres ke stdout sebelum JSON,
  # jadi output-nya bukan JSON murni. Ambil berkasnya, bukan disangka JSON.
  set +e
  T_MULAI=$(date +%s)
  # --wait dijalankan DI BELAKANG (latar) supaya loop tetap bisa membaca log
  # sambil berjalan: begitu id pod muncul, POD_ID langsung diisi. Kalau skrip
  # dihentikan / --wait kena timeout, trap tetap tahu pod mana yang harus dihapus
  # (dulu id baru dibaca sesudah loop, jadi pod yatim).
  runpodctl pod create --template-id "$TEMPLATE_ID" --gpu-id "$G" --gpu-count 1 \
        --cloud-type "$CLOUD" --container-disk-in-gb 30 --ports 22/tcp \
        --name "$NAMA" "${ARG_VOL[@]}" \
        --wait --wait-for ssh --wait-timeout 8m -o json > "$LOG_POD" 2>&1 &
  PID_TUNGGU=$!
  while kill -0 "$PID_TUNGGU" 2>/dev/null; do
    [ -z "$POD_ID" ] && POD_ID=$(sed -n 's/.*on pod \([a-z0-9]\{14\}\).*/\1/p' "$LOG_POD" 2>/dev/null | head -1)
    sleep 1
  done
  wait "$PID_TUNGGU"; RC=$?
  set -e
  OUT=$(cat "$LOG_POD")
  [ -z "$POD_ID" ] && POD_ID=$(printf '%s' "$OUT" | sed -n 's/.*on pod \([a-z0-9]\{14\}\).*/\1/p' | head -1)
  # --wait bisa keluar bukan-nol walau pod sudah jadi (mis. SSH telat). Kalau
  # wujud JSON berisi id, anggap berhasil — pod yang telanjur dibuat tetap
  # akan dihapus oleh trap.
  if [ -n "$(python3 -c 'import json,sys;t=open(sys.argv[1]).read();i=t.find("{");print(json.loads(t[i:]).get("id") or "")' "$LOG_POD" 2>/dev/null)" ]; then
    BISA=1; break
  fi
  if [ "$RC" = "0" ] && [ -n "$(python3 -c 'import json,sys;t=open(sys.argv[1]).read();i=t.find("{");json.loads(t[i:]);print(1)' "$LOG_POD" 2>/dev/null)" ]; then
    BISA=1; break
  fi
  catat "GPU $G gagal (rc=$RC): $(grep -vE '^\s*$' "$LOG_POD" | head -2 | tr '\n' ' ')"
done <<< "$GPU_SEMUA"
[ "$BISA" = "1" ] || { catat "tidak ada GPU yang bisa dipakai"; exit 3; }

# Buang baris progres "waiting for ssh ..." sebelum membaca JSON.
# JSON dari create boleh tidak lengkap (mis. keluar karena timeout), jadi ip/port
# diambil ulang dari `pod get` — sumber yang sama, tapi utuh.
POD_JSON=""
for _ in 1 2 3 4 5 6; do
  POD_JSON="$(runpodctl pod get "$POD_ID" -o json 2>/dev/null || true)"
  printf '%s' "$POD_JSON" | grep -q '"ip"' && break
  sleep 5
done
baca() { printf '%s' "$POD_JSON" | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
SSH_IP=$(baca '(d.get("ssh") or {}).get("ip") or ""')
SSH_PORT=$(baca '(d.get("ssh") or {}).get("port") or ""')
BIAYA=$(baca 'd.get("costPerHr")')
GPU_DIPAKAI=$(baca 'd.get("gpuId") or ""')
catat "pod $POD_ID siap (GPU $GPU_DIPAKAI, \$$BIAYA/jam): root@$SSH_IP -p $SSH_PORT"
[ -n "$SSH_IP" ] && [ -n "$SSH_PORT" ] || { catat "info SSH kosong dari API — pod $POD_ID tetap akan dihapus oleh trap"; exit 4; }

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
     -o ServerAliveInterval=20 -o ServerAliveCountMax=6 -i "$KUNCI" -p "$SSH_PORT" "root@$SSH_IP")
SCP=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KUNCI" -P "$SSH_PORT")

# --- 2. verifikasi image, bukan asumsi ---
SELISIH=$(( $(date +%s) - T_MULAI ))
catat "verifikasi image di pod"
# Waktu tunggu image + boot tercatat di sini; host yang lambat/bermasalah
# kelihatan dari angka ini (rujukan: ±20-60 dtk; pernah 4+ menit).
catat "pod siap ${SELISIH:-?} dtk setelah perintah create (image pull + boot)"
# `remotion --version` mencetak teks bantuan CLI (bukan nomor versi); versi paket
# dibaca dari package.json di node_modules.
# Catatan: di pod tanpa proyek ter-install, versi remotion proyek = TIDAK-ADA (wajar);
# yang membuktikan image sehat adalah node, render-gpu, dan chrome.
"${SSH[@]}" 'echo "node: $(node -v)"; echo "remotion (proyek): $(node -p "require('\''remotion/package.json'\'').version" 2>/dev/null || echo BELUM-ADA)"; echo "render-gpu: $(test -x /usr/local/bin/render-gpu && echo ADA || echo TIDAK-ADA)"; echo "chrome: $(ls /opt/chrome/.remotion/chrome-headless-shell/*/*/chrome-headless-shell 2>/dev/null || echo TIDAK-ADA)"' | tee -a "$LOG"

# --- 3. kirim proyek (tanpa node_modules/.git/out, karena bisa ratusan MB) ---
SISI=/root/kerja
catat "mengirim proyek ke $SISI"
"${SSH[@]}" "mkdir -p $SISI" 
tar -C "$PROYEK" -czf - \
    --exclude=node_modules --exclude=.git --exclude=out --exclude=out-pod \
    --exclude='*.mp4' --exclude='*.mov' --exclude='*.mkv' . \
  | "${SSH[@]}" "tar -C $SISI -xzf -"
catat "proyek terkirim"

# --- 4. dependensi proyek ---
# node_modules dari image ada di /workspace/remotion-app (paket lengkap), tapi
# `remotion render` membaca node_modules milik proyek.
#
# Tanpa TARUH_VOLUME: npm biasa (unduh dari internet).
# Dengan TARUH_VOLUME, semua usaha diarahkan supaya TIDAK ADA unduhan:
#   1. CACHE HIT   tar node_modules dengan kunci lockfile yang sama (untar 1-2 dtk)
#   2. CACHE ISI   tar lain di /workspace/cache/isi yang kuncinya sama
#   3. CACHE COPY  node_modules proyek lain di /workspace/proyek/<nama> atau
#                  /root/kerja-* (dipinjam kalau semua paket non-opsional cocok)
#   4. CACHE MISS  npm dengan _cacache di volume: tarball sudah ada -> tanpa unduh;
#                  paket baru terunduh sekali, lalu tar + _cacache disimpan
# Setelah pasang, tiap dependencies/devDependencies dicek ada dan versinya cocok
# dengan lockfile. Gagal -> npm sekali lagi; tetap gagal -> keluar (jangan render
# dengan node_modules yang belum pasti).
# Diukur di pod 22 Nov 2026: `npm ci` 242 paket = 8 dtk (jaringan pod cepat).
# Menyimpan tar cache 254 MB ke network volume justru makan ~2 menit, jadi cache
# TIDAK dinyalakan sebagai bawaan. Pakai CACHE_NPM=1 kalau registry lambat atau
# pohon dependensi besar.
if [ -z "${TARUH_VOLUME:-}" ] || [ -z "${CACHE_NPM:-}" ]; then
  catat "install dependensi via npm (bawaan; CACHE_NPM=1 untuk memakai cache volume)"
  "${SSH[@]}" "set -e; cd $SISI;     if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund --legacy-peer-deps; fi" 2>&1 | tee -a "$LOG"
else
  LOCK="$PROYEK/package-lock.json"; [ -f "$LOCK" ] || LOCK="$PROYEK/package.json"
  KUNCI_CACHE=$(sha256sum "$LOCK" | cut -c1-16)
  KUNCI_ISI=$(python3 - "$PROYEK" <<'PY'
import json,sys,os,hashlib
d=sys.argv[1]; lock=os.path.join(d,'package-lock.json'); out=[]
if os.path.exists(lock):
    j=json.load(open(lock))
    for k,v in j.get('packages',{}).items():
        if not k: continue
        ver=v.get('version') or (j.get('dependencies',{}).get(v.get('name') or '',{}) or {}).get('version')
        if ver: out.append(k+'@'+ver)
else:
    j=json.load(open(os.path.join(d,'package.json')))
    for sec in ('dependencies','devDependencies'):
        for n,v in (j.get(sec) or {}).items(): out.append(n+'@'+v)
print(hashlib.sha256("\n".join(sorted(set(out))).encode()).hexdigest()[:16])
PY
)
  VERIFIKASI=$(python3 - "$PROYEK" <<'PY'
import json,sys,os
d=sys.argv[1]; pj=json.load(open(os.path.join(d,'package.json')))
lock=os.path.join(d,'package-lock.json'); wajib=set()
for sec in ('dependencies','devDependencies'): wajib |= set((pj.get(sec) or {}).keys())
vers={}
if os.path.exists(lock):
    j=json.load(open(lock))
    for k,v in j.get('packages',{}).items():
        if k: vers[k.split('node_modules/',1)[-1]]=(v or {}).get('version')
print(" ".join(n+'='+(vers.get(n) or '-') for n in sorted(wajib)))
PY
)
  catat "dependensi lewat volume (kunci lock $KUNCI_CACHE, kunci isi $KUNCI_ISI, paket wajib $(printf '%s' "$VERIFIKASI" | wc -w))"
  PASANG=$(cat <<'INPOD'
set -e
CACHE=/workspace/cache
export npm_config_cache=$CACHE/npm-cacache
export npm_config_fetch_retries=5 npm_config_fetch_timeout=300000
mkdir -p "$CACHE/npm-cacache" "$CACHE/isi"
@BERSIH@
BARU=""
if [ -f "$CACHE/node_modules-@KUNCI_LOCK@.tar.gz" ]; then
  echo "CACHE HIT (kunci lockfile)"
  tar xzf "$CACHE/node_modules-@KUNCI_LOCK@.tar.gz"
elif [ -f "$CACHE/isi/index.tsv" ] && awk -v k=@KUNCI_ISI@ '$1==k{print $2; exit}' "$CACHE/isi/index.tsv" | grep -q .; then
  NAMATAR=$(awk -v k=@KUNCI_ISI@ '$1==k{print $2; exit}' "$CACHE/isi/index.tsv")
  echo "CACHE ISI (tar $NAMATAR isinya identik)"
  tar xzf "$CACHE/isi/$NAMATAR.tar.gz"
else
  echo "CACHE MISS (npm, _cacache di volume)"
  BARU=1
  for CALON in /workspace/proyek/*/node_modules /root/kerja-*/node_modules; do
    [ -d "$CALON" ] || continue
    if node -e '
const fs=require("fs"),path=require("path");
const lock=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const calon=process.argv[2], kurang=[];
for (const [k,v] of Object.entries(lock.packages||{})) {
  if (!k || !v.version || v.optional) continue;
  const p=k.replace(/^node_modules\//,"");
  let j=null; try{j=JSON.parse(fs.readFileSync(path.join(calon,p,"package.json"),"utf8"))}catch(e){}
  if (!j || j.version!==v.version) kurang.push(p);
}
process.exit(kurang.length?1:0);
' package-lock.json "$CALON" 2>/dev/null; then
      echo "CACHE COPY (node_modules proyek lain isinya identik: $CALON)"
      cp -a "$CALON" node_modules
      BARU=""
      break
    fi
  done
  if [ ! -d node_modules ]; then
    if [ -f package-lock.json ]; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund --legacy-peer-deps; else npm install --no-audit --no-fund --legacy-peer-deps; fi
  fi
fi
CEK_PAKET() {
  local hilang="" p v pv
  for ITEM in @VERIFIKASI@; do
    p="${ITEM%%=*}"; v="${ITEM#*=}"
    if [ ! -e "node_modules/$p" ]; then hilang="$hilang $p(hilang)"
    elif [ "$v" != "-" ]; then
      pv=$(node -e 'try{console.log(require("./node_modules/"+process.argv[1]+"/package.json").version)}catch(e){console.log("")}' "$p" 2>/dev/null)
      [ "$pv" = "$v" ] || hilang="$hilang $p(${pv:-?}!=$v)"
    fi
  done
  if [ -n "$hilang" ]; then echo "CEK GAGAL:$hilang"; return 1; fi
  echo "CEK OK (paket wajib ada, versi cocok)"
}
if ! CEK_PAKET; then
  echo "paket belum cocok — npm sekali lagi (tarball dari _cacache volume)"
  rm -rf node_modules
  if [ -f package-lock.json ]; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund --legacy-peer-deps; else npm install --no-audit --no-fund --legacy-peer-deps; fi
  BARU=1
  CEK_PAKET || { echo "paket tetap tidak cocok — berhenti, jangan render"; exit 6; }
fi
if [ -n "$BARU" ]; then
  tar czf "$CACHE/isi/node_modules-@KUNCI_ISI@.tar.gz" node_modules
  cp "$CACHE/isi/node_modules-@KUNCI_ISI@.tar.gz" "$CACHE/node_modules-@KUNCI_LOCK@.tar.gz"
  grep -v "^@KUNCI_ISI@"$'\t' "$CACHE/isi/index.tsv" 2>/dev/null > "$CACHE/isi/index.tmp" || true
  printf '%s\t%s\n' "@KUNCI_ISI@" "node_modules-@KUNCI_ISI@" >> "$CACHE/isi/index.tmp"
  mv "$CACHE/isi/index.tmp" "$CACHE/isi/index.tsv"
  echo "CACHE DISIMPAN"
fi
du -sh node_modules
INPOD
)
  PASANG=${PASANG//@KUNCI_LOCK@/$KUNCI_CACHE}
  PASANG=${PASANG//@KUNCI_ISI@/$KUNCI_ISI}
  PASANG=${PASANG//@VERIFIKASI@/$VERIFIKASI}
  PASANG=${PASANG//@NAMA@/$NAMA}
  BERSIH_CMD=""
  if [ -n "${BERSIHKAN_CACHE:-}" ]; then
    BERSIH_CMD='echo "cache volume dibersihkan dulu (BERSIHKAN_CACHE=1)"; rm -rf "$CACHE/isi" "$CACHE"/*.tar.gz; mkdir -p "$CACHE/isi"'
    catat "BERSIHKAN_CACHE=1: tar cache di volume dihapus sebelum render"
  fi
  PASANG=${PASANG//@BERSIH@/$BERSIH_CMD}
  # simulasi lokal (uji di mesin ini tanpa pod): volume → folder, isi kerja → /tmp/sim2/kerja
  if [ -n "${SIMULASI_LOKAL:-}" ]; then
    PASANG=${PASANG//\/workspace\/cache/$SIMULASI_LOKAL}
    PASANG=${PASANG//\/workspace\/proyek/$SIMULASI_LOKAL/proyek}
  fi
  PASANG="cd $SISI
$PASANG"
  if [ -n "${SIMULASI_LOKAL:-}" ]; then
    bash -c "$PASANG" 2>&1 | tee -a "$LOG"
  else
    "${SSH[@]}" "$PASANG" 2>&1 | tee -a "$LOG"
  fi
fi
# --- 5. render ---
KELUARAN="/root/keluaran/$(basename "$KOMPOSISI")-$(date +%Y%m%d-%H%M).mp4"
catat "render $KOMPOSISI -> $KELUARAN"
MULAI=$(date +%s)
"${SSH[@]}" "mkdir -p /root/keluaran; cd $SISI; RENDER_CODE=h264 RENDER_CRF=${RENDER_CRF:-18} render-gpu $ENTRY $KOMPOSISI $KELUARAN" 2>&1 | tee -a "$LOG"
catat "render selesai dalam $(( $(date +%s) - MULAI )) detik"

# --- 6. verifikasi hasil di pod, lalu tarik ---
catat "verifikasi hasil"
"${SSH[@]}" "ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,nb_frames -show_entries format=duration,size -of json '$KELUARAN'" | tee -a "$LOG"

TUJUAN="$KELUARAN_DIR/$(basename "$KELUARAN")"
"${SCP[@]}" "root@$SSH_IP:$KELUARAN" "$TUJUAN"
catat "hasil di $TUJUAN ($(du -h "$TUJUAN" | cut -f1))"

# Cek tidak hitam: YAVG frame tengah > 10.
YAVG=$(ffmpeg -hide_banner -i "$TUJUAN" -vf "select=eq(n\,$(( $(ffprobe -v error -show_entries stream=nb_frames -of csv=p=0 "$TUJUAN") / 2 ))),signalstats,metadata=mode=print:key=lavfi.signalstats.YAVG" -frames:v 1 -f null - 2>&1 | grep -oE 'YAVG=[0-9.]+' | head -1 | cut -d= -f2)
catat "YAVG frame tengah: ${YAVG:-?} (>10 = tidak hitam)"
awk -v y="${YAVG:-0}" 'BEGIN { if (y+0 <= 10) { print "[peringatan] hasil tampak hitam/kosong — periksa log render" } }' | tee -a "$LOG"

catat "selesai"
