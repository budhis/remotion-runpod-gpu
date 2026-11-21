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
#   GPU           default "NVIDIA A40"   (A40 = satu-satunya stok High saat panduan ini ditulis)
#   GPU_CADANGAN  daftar dipisah koma kalau GPU utama habis
#   CLOUD         SECURE | COMMUNITY     (default SECURE)
#   TARUH_VOLUME  id network volume untuk cache node_modules (opsional)
#   HAPUS_POD     1 (default) | 0 kalau mau menyimpan pod untuk debug
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

PROYEK=${1:?pakai: render-pod.sh <direktori-proyek> <entry> <komposisi>}
ENTRY=${2:?entry, mis. src/index.tsx}
KOMPOSISI=${3:?komposisi, mis. MainComp}
PROYEK=$(cd "$PROYEK" && pwd)

TEMPLATE_ID=${TEMPLATE_ID:-2r4zu7wvgp}
GPU=${GPU:-"NVIDIA A40"}
GPU_CADANGAN=${GPU_CADANGAN:-"NVIDIA L4,NVIDIA GeForce RTX 5090,NVIDIA RTX 6000 Ada Generation"}
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
ARG_VOL=()
[ -n "${TARUH_VOLUME:-}" ] && ARG_VOL=(--network-volume-id "$TARUH_VOLUME")

catat "membuat pod dari template $TEMPLATE_ID (GPU $GPU, cloud $CLOUD)"
BISA=0
for G in "$GPU" $(printf '%s' "$GPU_CADANGAN" | tr ',' ' '); do
  OUT=$(runpodctl pod create --template-id "$TEMPLATE_ID" --gpu-id "$G" --gpu-count 1 \
        --cloud-type "$CLOUD" --container-disk-in-gb 30 --ports 22/tcp \
        --name "$NAMA" "${ARG_VOL[@]}" \
        --wait --wait-for ssh --wait-timeout 8m -o json 2>&1) && { BISA=1; break; }
  catat "GPU $G gagal: $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
done
[ "$BISA" = "1" ] || { catat "tidak ada GPU yang bisa dipakai"; exit 3; }

POD_ID=$(printf '%s' "$OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id"))')
SSH_IP=$(printf '%s' "$OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);s=d.get("ssh") or {};print(s.get("ip") or "")')
SSH_PORT=$(printf '%s' "$OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);s=d.get("ssh") or {};print(s.get("port") or "")')
BIAYA=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("costPerHr"))')
catat "pod $POD_ID siap: root@$SSH_IP -p $SSH_PORT (\$$BIAYA/jam)"
[ -n "$SSH_IP" ] && [ -n "$SSH_PORT" ] || { catat "info SSH kosong dari API"; exit 4; }

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
     -o ServerAliveInterval=20 -o ServerAliveCountMax=6 -i "$KUNCI" -p "$SSH_PORT" "root@$SSH_IP")
SCP=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KUNCI" -P "$SSH_PORT")

# --- 2. verifikasi image, bukan asumsi ---
catat "verifikasi image di pod"
"${SSH[@]}" 'echo "node: $(node -v)"; echo "remotion: $(remotion --version 2>/dev/null || echo TIDAK-ADA)"; echo "render-gpu: $(test -x /usr/local/bin/render-gpu && echo ADA || echo TIDAK-ADA)"; echo "chrome: $(ls /opt/chrome/.remotion/chrome-headless-shell/*/*/chrome-headless-shell 2>/dev/null || echo TIDAK-ADA)"' | tee -a "$LOG"

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
# `remotion render` membaca node_modules milik proyek. Kalau proyek punya
# package-lock.json, pakai `npm ci`; kalau tidak, `npm install`. Cache di volume
# (kalau TARUH_VOLUME diisi) membuat pod berikutnya tidak install ulang.
if [ -n "${TARUH_VOLUME:-}" ]; then
  catat "dependensi lewat cache volume"
  "${SSH[@]}" "set -e; cd $SISI; \
    if [ -f node_modules.tar.gz ]; then tar xzf node_modules.tar.gz; \
    elif [ -d /workspace/dep/node_modules ]; then ln -sfn /workspace/dep/node_modules node_modules; fi; \
    if [ ! -d node_modules ]; then \
      if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund --legacy-peer-deps; fi; \
      tar czf node_modules.tar.gz node_modules && mv node_modules.tar.gz /workspace/dep/ 2>/dev/null || true; fi" 2>&1 | tee -a "$LOG"
else
  catat "install dependensi proyek (pertama kali bisa 1-3 menit)"
  "${SSH[@]}" "set -e; cd $SISI; \
    if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund --legacy-peer-deps; fi" 2>&1 | tee -a "$LOG"
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
