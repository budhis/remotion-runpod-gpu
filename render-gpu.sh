#!/usr/bin/env bash
# render-gpu — panggil `remotion render` dengan setelan GPU/GL yang aman untuk
# pod RunPod headless (tanpa display). Dipasang di /usr/local/bin/render-gpu
# supaya bisa dipanggil dari direktori proyek mana pun di dalam Pod.
#
# Pemakaian:
#   render-gpu <entry> <komposisi> <keluaran.mp4> [opsi tambahan remotion]
#   render-gpu src/index.ts MainComp out/video.mp4
#   render-gpu src/index.ts MainComp out/video.mp4 --crf=15 --concurrency=8
#   render-gpu              (tanpa argumen → cetak bantuan ini)
#
# Variabel lingkungan (opsional):
#   RENDER_GL          backend GL: swangle (default) | angle | angle-egl | swiftshader | vulkan
#   RENDER_CONCURRENCY jumlah tab paralel (kosong = biarkan Remotion menghitung dari cgroup)
#   RENDER_CRF         kualitas H.264 (kosong = bawaan Remotion)
#   RENDER_CODE        codec (kosong = h264)
#   RENDER_FRAMES      rentang frame, mis. 0-59 atau 100 (kosong = semua frame)
#   RENDER_GPU_INFO    1 = cetak info GPU sebelum render (default 1)
#
# Kenapa swangle sebagai default: di pod RunPod tanpa display, --gl=angle gagal
# inisialisasi Vulkan/EGL. swangle (ANGLE di atas SwiftShader/Vulkan) adalah
# backend yang terbukti jalan di pod headless.
set -euo pipefail

ENTRY=${1:-}
KOMPOSISI=${2:-}
KELUARAN=${3:-}

if [ -z "$ENTRY" ] || [ -z "$KOMPOSISI" ] || [ -z "$KELUARAN" ]; then
  echo "Pakai: render-gpu <entry> <komposisi> <keluaran.mp4> [opsi remotion]" >&2
  echo "Contoh: render-gpu src/index.ts MainComp out/video.mp4" >&2
  exit 2
fi
shift 3

GL=${RENDER_GL:-swangle}

if [ ! -f "$ENTRY" ]; then
  echo "[render-gpu] entry tidak ditemukan: $ENTRY (cwd: $PWD)" >&2
  exit 2
fi

# Jangan pakai nproc untuk concurrency: di pod, nproc melihat core host,
# sedangkan cgroup hanya memberi sebagian. Remotion menolak nilai yang lebih
# besar dari core yang terlihat cgroup, jadi biarkan kosong.
ARGS=(--gl="$GL")
[ -n "${RENDER_CRF:-}" ]         && ARGS+=(--crf="$RENDER_CRF")
[ -n "${RENDER_CODE:-}" ]        && ARGS+=(--codec="$RENDER_CODE")
[ -n "${RENDER_CONCURRENCY:-}" ] && ARGS+=(--concurrency="$RENDER_CONCURRENCY")
[ -n "${RENDER_FRAMES:-}" ]      && ARGS+=(--frames="$RENDER_FRAMES")

echo "[render-gpu] entry=$ENTRY komposisi=$KOMPOSISI keluaran=$KELUARAN gl=$GL"

# Info GPU: menegaskan driver NVIDIA benar-benar sampai ke container.
if [ "${RENDER_GPU_INFO:-1}" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
    || echo "[render-gpu] nvidia-smi gagal (render tetap jalan)"
else
  echo "[render-gpu] nvidia-smi tidak tersedia — render memakai CPU/SwiftShader"
fi

case "$KELUARAN" in
  */*) mkdir -p "$(dirname "$KELUARAN")" ;;
esac

# Pakai bin lokal dulu (versi CLI yang sama dengan paket proyek), lalu bin
# global hasil npm -g dari image ini, terakhir npx. `npx remotion` TIDAK
# berfungsi: bin paket @remotion/cli bernama `remotion`, bukan `remotion`
# sebagai paket — npx selesai dengan "could not determine executable to run".
if [ -x node_modules/.bin/remotion ]; then
  REMOTION=(node_modules/.bin/remotion)
elif command -v remotion >/dev/null 2>&1; then
  REMOTION=(remotion)
else
  REMOTION=(npx --yes --package @remotion/cli remotion)
fi

MULAI=$(date +%s)
"${REMOTION[@]}" render "$ENTRY" "$KOMPOSISI" "$KELUARAN" "${ARGS[@]}" "$@"
DURASI=$(( $(date +%s) - MULAI ))

SIZE=$(du -h "$KELUARAN" | cut -f1)
echo "[render-gpu] selesai dalam ${DURASI} detik — $KELUARAN ($SIZE)"
