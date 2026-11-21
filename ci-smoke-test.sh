#!/usr/bin/env bash
# Uji isi image setelah build — dijalankan di dalam image oleh CI.
# Tujuan: membuktikan image bisa merender, bukan cuma bisa di-build.
set -euo pipefail

echo "== versi & berkas =="
node -v
npm -v
test -x /usr/local/bin/render-gpu && echo "render-gpu: ada"
bash -n /usr/local/bin/render-gpu && echo "render-gpu: sintaks ok"
test -x /usr/local/bin/start.sh && echo "entrypoint: ada"
test -x /usr/sbin/sshd && echo "sshd: ada"
test -f /etc/ssh/ssh_host_ed25519_key && echo "host key: ada"
test -x "$REMOTION_BROWSER_EXECUTABLE" && echo "chrome: ada ($REMOTION_BROWSER_EXECUTABLE)"
command -v remotion >/dev/null && echo "remotion global: ada ($(remotion --version 2>/dev/null || echo '?'))"

echo "== paket =="
cd /workspace/remotion-app
node -e 'for (const p of ["remotion","@remotion/renderer","@remotion/three","@remotion/tailwind-v4","three","d3","lucide-react"]) require(p); console.log("paket remotion: ok")'

echo "== render uji 5 frame =="
cat > smoke.tsx <<'EOF'
import React from "react";
import { AbsoluteFill, Composition, registerRoot } from "remotion";

const Smoke: React.FC = () => (
  <AbsoluteFill style={{ background: "#123", color: "#fff", fontSize: 48, alignItems: "center", justifyContent: "center" }}>
    render-gpu smoke
  </AbsoluteFill>
);

const Root: React.FC = () => (
  <Composition id="Smoke" component={Smoke} durationInFrames={10} fps={10} width={320} height={180} />
);

registerRoot(Root);
EOF

RENDER_GPU_INFO=0 RENDER_FRAMES=0-4 render-gpu smoke.tsx Smoke /tmp/smoke.mp4
FRAMES=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 /tmp/smoke.mp4)
echo "frame ter-render: $FRAMES"
test "$FRAMES" = "5"
echo "SEMUA UJI LOLOS"
