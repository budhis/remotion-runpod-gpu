#!/usr/bin/env bash
# Entrypoint pod RunPod: SSH otomatis aktif, lalu jalankan CMD.
#
# Kontrak: container HARUS punya proses yang bertahan — pod yang container-nya
# keluar akan restart terus / macet di "initializing".
#
# Yang terbukti dari uji pod (21-22 Nov 2026):
#   - RunPod menyuntik $PUBLIC_KEY saat pod dibuat; tanpa dipasang ke
#     authorized_keys, SSH pod tidak bisa dipakai.
#   - `/usr/sbin/sshd -D` (foreground, di-background-kan di sini) lebih andal
#     daripada `service ssh start` di container tanpa systemd.
set -u

if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  # Baris berulang tidak berbahaya; ambil yang belum ada saja.
  printf '%s\n' "$PUBLIC_KEY" | while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qxF "$k" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$k" >> /root/.ssh/authorized_keys
  done
  chmod 600 /root/.ssh/authorized_keys
  echo "[entrypoint] PUBLIC_KEY dipasang ke /root/.ssh/authorized_keys"
else
  echo "[entrypoint] PUBLIC_KEY kosong — SSH tanpa kunci (pakai web terminal RunPod)"
fi

mkdir -p /run/sshd
/usr/sbin/sshd -D -p 22 -e &
echo "[entrypoint] sshd jalan di port 22"

exec "$@"
