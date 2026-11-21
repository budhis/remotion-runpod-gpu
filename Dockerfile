# Image render Remotion GPU untuk pod RunPod.
#
# Dasar: nvidia/cuda runtime (Ubuntu 22.04) + Node.js 22 LTS + Chrome Headless
# Shell + ekosistem Remotion (react 19, three/R3F, d3, mapbox/maplibre, tailwind).
#
# Catatan yang dipertahankan dari pengujian nyata pod (21-22 Nov 2026):
#  - Ubuntu 22.04 punya `libasound2` (24.04 menamainya libasound2t64 → apt gagal).
#  - sshd dibuat siap pakai saat build (`/run/sshd`, host key) → pod tidak
#    macet "initializing" dan tidak perlu apt-get saat boot.
#  - Remotion TIDAK butuh CUDA untuk render; GPU dipakai browser untuk
#    compositing. Image CUDA dipakai karena driver/video caps disuntik RunPod.
#  - `npx remotion browser ensure` menyimpan browser di `<cwd>/.remotion/`,
#    jadi cwd di-pin ke /opt/chrome.
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ARG NODE_MAJOR=22
ARG REMOTION_VERSION=4.0.545
ARG THREE_VERSION=0.180.0
ARG FIBER_VERSION=9.8.2

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics \
    NODE_ENV=development

# 1. Utilitas sistem + pustaka Chromium (GPU/EGL/Vulkan disiapkan NVIDIA+mesa).
#    `libatk1.0-0` dll. = dependensi runtime Chrome Headless Shell.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl wget git build-essential cmake ca-certificates gnupg \
        openssh-server openssh-client procps tmux unzip \
        python3 python3-pip \
        ffmpeg \
        libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libdrm2 libgbm1 libasound2 libxrandr2 libxkbcommon0 \
        libxfixes3 libxcomposite1 libxdamage1 libpango-1.0-0 libcairo2 \
        libegl1 libgl1-mesa-glx libgl1-mesa-dri libgles2 libexpat1 \
        fonts-dejavu-core fonts-liberation fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# 2. Node.js 22 LTS (NodeSource).
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node -v && npm -v

# 3. Ekosistem Remotion lengkap. Versi dipin (bukan ^) supaya cache layer di CI
#    tidak pecah tiap rilis baru; naikkan lewat argumen build.
#    `--no-audit --no-fund` memangkas waktu npm; `--legacy-peer-deps` karena
#    beberapa peer (mis. @remotion/three) belum menyatakan React 19.
WORKDIR /workspace/remotion-app

RUN npm init -y >/dev/null \
    && npm install --legacy-peer-deps --no-audit --no-fund \
        "react@^19.0.0" \
        "react-dom@^19.0.0" \
        typescript \
        @types/react \
        @types/react-dom \
        @types/node \
        "remotion@${REMOTION_VERSION}" \
        "@remotion/cli@${REMOTION_VERSION}" \
        "@remotion/renderer@${REMOTION_VERSION}" \
        "@remotion/player@${REMOTION_VERSION}" \
        "@remotion/bundler@${REMOTION_VERSION}" \
        "@remotion/tailwind-v4@${REMOTION_VERSION}" \
        "@remotion/transitions@${REMOTION_VERSION}" \
        "@remotion/layout-utils@${REMOTION_VERSION}" \
        "@remotion/shapes@${REMOTION_VERSION}" \
        "@remotion/paths@${REMOTION_VERSION}" \
        "@remotion/noise@${REMOTION_VERSION}" \
        "@remotion/motion-blur@${REMOTION_VERSION}" \
        "@remotion/animation-utils@${REMOTION_VERSION}" \
        "@remotion/google-fonts@${REMOTION_VERSION}" \
        "@remotion/fonts@${REMOTION_VERSION}" \
        "@remotion/captions@${REMOTION_VERSION}" \
        "@remotion/install-whisper-cpp@${REMOTION_VERSION}" \
        "@remotion/media-utils@${REMOTION_VERSION}" \
        "@remotion/sfx@${REMOTION_VERSION}" \
        "@remotion/lottie@${REMOTION_VERSION}" \
        "@remotion/gif@${REMOTION_VERSION}" \
        "@remotion/webcodecs@${REMOTION_VERSION}" \
        "@remotion/three@${REMOTION_VERSION}" \
        "three@${THREE_VERSION}" \
        @types/three \
        "@react-three/fiber@${FIBER_VERSION}" \
        @react-three/drei \
        lottie-web \
        d3 \
        @types/d3 \
        maplibre-gl \
        mapbox-gl \
        lucide-react \
        tailwindcss \
        clsx \
        tailwind-merge \
    && npm cache clean --force

# 3a. render-gpu tetap bisa jalan dari folder proyek mana pun: pasang juga
#     CLI global (`remotion`). Kalau proyek punya node_modules sendiri, bin
#     lokal yang dipakai lebih dulu oleh skrip.
RUN npm install -g --no-audit --no-fund "@remotion/cli@${REMOTION_VERSION}" \
    && command -v remotion \
    && npm cache clean --force

# 3b. Chrome Headless Shell dipanggang ke image (tanpa unduh ±120 MB tiap pod).
#     cwd sengaja /opt/chrome: `browser ensure` menulis ke `<cwd>/.remotion/`.
WORKDIR /opt/chrome
RUN npm install --no-save --no-audit --no-fund "@remotion/cli@${REMOTION_VERSION}" \
    && npx remotion browser ensure \
    && CHROME=$(find /opt/chrome/.remotion -type f -name 'chrome-headless-shell' | head -1) \
    && test -n "$CHROME" \
    && { ldd "$CHROME" | grep -E '/\*' | head -5 || true; } \
    && echo "chrome: $CHROME"

ENV REMOTION_BROWSER_EXECUTABLE=/opt/chrome/.remotion/chrome-headless-shell/linux64/chrome-headless-shell-linux64/chrome-headless-shell

# 4. render-gpu.sh sebagai perintah global. `sed -i 's/\r$//'` membuang CRLF
#    kalau file pernah disunting dari Windows (CRLF membuat bash gagal dengan
#    "bad interpreter: /usr/bin/env bash^M").
COPY render-gpu.sh /usr/local/bin/render-gpu
RUN sed -i 's/\r$//' /usr/local/bin/render-gpu \
    && chmod +x /usr/local/bin/render-gpu \
    && bash -n /usr/local/bin/render-gpu

# 5. sshd siap pakai: /run/sshd + host key dibuat saat build. Tanpa ini pod
#    buatan API bisa berhenti di status "initializing".
RUN mkdir -p /run/sshd /root/.ssh && ssh-keygen -A

# 6. Entrypoint: pasang $PUBLIC_KEY RunPod lalu jalankan sshd, terus exec CMD.
COPY docker-entrypoint.sh /usr/local/bin/start.sh
RUN sed -i 's/\r$//' /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

WORKDIR /workspace
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["sleep", "infinity"]
