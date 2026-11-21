#!/usr/bin/env bash
# Uji render 30 detik (900 frame) di dalam image — dipakai CI.
# Tujuan: membuktikan image sanggup render durasi nyata, bukan cuma 5 frame.
set -euo pipefail

echo "== versi =="
node -v
npm -v
test -x /usr/local/bin/render-gpu && echo "render-gpu: ada"
bash -n /usr/local/bin/render-gpu && echo "render-gpu: sintaks ok"
test -x /usr/sbin/sshd && echo "sshd: ada"
test -f /etc/ssh/ssh_host_ed25519_key && echo "host key: ada"
if [ -n "${REMOTION_BROWSER_EXECUTABLE:-}" ] && [ -x "$REMOTION_BROWSER_EXECUTABLE" ]; then echo "chrome: ada (env)"; else echo "chrome: env kosong, render-gpu yang mencarikan"; fi
command -v remotion >/dev/null && echo "remotion global: ada"

echo "== paket =="
cd /workspace/remotion-app
node -e 'for (const p of ["remotion","@remotion/renderer","@remotion/three","three","d3","lucide-react"]) require(p); console.log("paket: ok")'

echo "== render 30 detik (900 frame, 1920x1080, 30 fps) =="
cat > durasi30.tsx <<'EOF'
import React from "react";
import {
  AbsoluteFill,
  Composition,
  interpolate,
  registerRoot,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

const DETIK = 30;
const SEGMEN = 10;

const Shot: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const detik = frame / fps;
  const seg = Math.min(SEGMEN - 1, Math.floor(detik / (DETIK / SEGMEN)));
  const p = spring({
    frame: frame - seg * (DETIK / SEGMEN) * fps,
    fps,
    config: { damping: 200, stiffness: 120 },
  });
  const hue = (seg * 36) % 360;
  const geserY = interpolate(p, [0, 1], [1080, 0]);
  return (
    <AbsoluteFill style={{ background: `linear-gradient(180deg, hsl(${hue}, 60%, 18%), #000)` }}>
      <AbsoluteFill
        style={{
          transform: `translateY(${geserY}px)`,
          color: "#ffffff",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <h1 style={{ fontSize: 96, margin: 0, letterSpacing: "0.02em" }}>SEGMEN {seg + 1}</h1>
        <p style={{ fontSize: 36, opacity: 0.6 }}>
          detik {detik.toFixed(1)} / {DETIK} - frame {frame}
        </p>
      </AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: 0,
          bottom: 0,
          height: 8,
          width: `${((frame % 60) / 60) * 1920}px`,
          background: "#ffffff",
        }}
      />
    </AbsoluteFill>
  );
};

const Root: React.FC = () => (
  <Composition id="Durasi30" component={Shot} durationInFrames={900} fps={30} width={1920} height={1080} />
);

registerRoot(Root);
EOF

MULAI=$(date +%s)
RENDER_GPU_INFO=0 RENDER_CODE=h264 RENDER_CRF=18 render-gpu durasi30.tsx Durasi30 /tmp/durasi30.mp4
echo "durasi dinding: $(( $(date +%s) - MULAI )) detik"

echo "== verifikasi =="
FRAME=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 /tmp/durasi30.mp4)
echo "frame: $FRAME"
test "$FRAME" = "900"

STRIM=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name -of csv=p=0 /tmp/durasi30.mp4)
echo "strim: $STRIM"
echo "ukuran: $(du -h /tmp/durasi30.mp4 | cut -f1)"

# Isi frame tidak boleh hitam total. Tanpa PIL: pakai signalstats ffmpeg.
YAVG=$(ffmpeg -hide_banner -i /tmp/durasi30.mp4 -vf "select=eq(n\,450),signalstats,metadata=mode=print:key=lavfi.signalstats.YAVG" -frames:v 1 -f null - 2>&1 | grep -oE 'YAVG=[0-9.]+' | head -1 | cut -d= -f2)
echo "frame 450 YAVG: ${YAVG:-?} (>10 = berisi)"
test -n "$YAVG"
awk -v y="$YAVG" 'BEGIN { exit (y > 10 ? 0 : 1) }'

echo "SEMUA UJI LOLOS"
