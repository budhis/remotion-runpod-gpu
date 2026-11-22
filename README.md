# Image GPU RunPod untuk render Remotion

Repo ini berisi satu hal: **image Docker GPU yang siap render Remotion di pod RunPod** — Node 22, Chrome Headless Shell, ekosistem Remotion lengkap, Chrome dipanggang (tanpa unduh tiap pod), sshd aktif saat boot, dan perintah global `render-gpu`.

```
.
├── Dockerfile
├── render-gpu.sh                 # → /usr/local/bin/render-gpu
├── docker-entrypoint.sh          # → /usr/local/bin/start.sh (sshd + $PUBLIC_KEY)
├── ci-smoke-test.sh              # dipakai CI: uji isi image + render 5 frame
├── ci-durasi30.sh                # dipakai CI: render 30 detik (900 frame) 1920x1080
├── .dockerignore
├── ├── render-pod.sh                  # siklus penuh: pod → kirim → install → render → tarik → hapus
├── PANDUAN-RENDER-POD.md          # panduan pemakaian (GPU, biaya, cache, jebakan)
.hadolint.yaml
└── .github/
    └── workflows/
        └── build-runpod-remotion.yml
```

## 1. Secret GitHub

`Settings → Secrets and variables → Actions`:

| Nama | Isi |
| --- | --- |
| `DOCKERHUB_USERNAME` | username Docker Hub |
| `DOCKERHUB_TOKEN` | Access Token hub.docker.com (bukan password) |

`GITHUB_TOKEN` otomatis; itu yang dipakai untuk GHCR. **Kalau dua secret Docker Hub kosong, workflow tetap sukses** dan image hanya di-push ke GHCR (ada `::warning::` di log).

## 2. Build

Push ke `main` (path `Dockerfile`, `render-gpu.sh`, `docker-entrypoint.sh`, `.dockerignore`, workflow) atau `Run workflow` dari tab Actions.

- Tag: `latest` (atau `image_tag` saat manual) + `sha-<commit>`.
- Build pertama ±8–15 menit (npm install ekosistem + Chrome ±120 MB); berikutnya 2–4 menit berkat `cache-from: type=gha`.
- Langkah 9 **menjalankan** image dan menguji `node -v`, `bash -n render-gpu`, keberadaan Chrome cache, host key sshd, dan `require()` paket Remotion. Build hijau tanpa langkah ini hanya berarti layer berhasil dibuat.

## 3. Pasang sebagai Template RunPod

```bash
# GHCR public (default untuk repo publik)
runpodctl template create \
  --name remotion-gpu \
  --image ghcr.io/<owner>/remotion-runpod-gpu:latest \
  --ports "22/tcp" --port-labels "22=ssh" \
  --container-disk-in-gb 30
```

Kalau paket GHCR **private**:

```bash
printenv GHCR_PAT | runpodctl registry create --name ghcr --username <github-user> --password-stdin
runpodctl registry list          # ambil id
# tambahkan --registry-auth-id <id> pada template create
```

Saran: pin ke `sha-...` atau tag versi, bukan `latest` — kalau CI menimpa `latest`, pod yang restart bisa tiba-tiba memakai image berbeda.

## 4. Render di Pod

```bash
cd /workspace/proyek-kamu
render-gpu src/index.ts MainComp out/video.mp4
```

Siklus dari mesin lokal (buat pod → kirim proyek → install → render → tarik → hapus pod):

```bash
curl -fsSL https://raw.githubusercontent.com/budhis/remotion-runpod-gpu/main/render-pod.sh -o ~/render-pod.sh
chmod +x ~/render-pod.sh
~/render-pod.sh <direktori-proyek> src/index.tsx MainComp
```

GPU dicoba berurutan sesuai prioritas; bawaan mulai dari yang paling murah (lihat
`PANDUAN-RENDER-POD.md` bagian 3). Atur sendiri mis. `GPU="NVIDIA GeForce RTX 4090,NVIDIA L4"`.

`render-gpu` = `remotion render` dengan `--gl=swangle` (backend yang terbukti jalan di pod headless; `--gl=angle` gagal inisialisasi Vulkan/EGL tanpa display), ditambah pembuatan folder keluaran, cek entry, dan info GPU.

Variabel lingkungan yang didukung:

| Variabel | Default | Arti |
| --- | --- | --- |
| `RENDER_GL` | `swangle` | `angle`, `angle-egl`, `swiftshader`, `vulkan` |
| `RENDER_CRF` | – | kualitas H.264 (mis. `18`) |
| `RENDER_CONCURRENCY` | – | tab paralel; kosong = Remotion hitung dari cgroup |
| `RENDER_CODE` | – | codec (`h264`, `vp8`, …) |
| `RENDER_FRAMES` | – | mis. `0-59` untuk uji cepat |
| `RENDER_GPU_INFO` | `1` | cetak `nvidia-smi` sebelum render |

Opsi lain diteruskan apa adanya ke `remotion render`, mis.:

```bash
render-gpu src/index.ts MainComp out/video.mp4 --crf=16 --concurrency=8
RENDER_FRAMES=0-119 render-gpu src/index.ts MainComp out/uji.mp4
```

Uji cepat setelah pod hidup:

```bash
render-gpu --help            # → pesan pakai (exit 2)
RENDER_FRAMES=0-29 render-gpu src/index.ts MainComp out/uji-30f.mp4
ffprobe -v error -show_entries stream=nb_frames -of csv=p=0 out/uji-30f.mp4
```

## 5. Yang perlu diperhatikan

- **Proyek kamu butuh dependensinya sendiri.** Image ini memasang Remotion + React + three/R3F + d3 + mapbox + tailwind secara global di `/workspace/remotion-app`, tapi `remotion render` membaca `node_modules` dari proyek. Kalau proyek belum punya, `cd proyek && npm install` (±1–2 menit, sekali per pod). Untuk pod berulang, cache `node_modules` di network volume.
- **Jangan pakai `nproc` untuk `--concurrency`.** Di pod, `nproc` melihat core host (sampai 112) sedangkan cgroup hanya memberi sebagian; Remotion menolak nilai itu dan mati dalam hitungan detik. Biarkan kosong atau isi ≤ core cgroup.
- **GPU bukan syarat render Remotion.** Remotion merender lewat browser (compositing + encoding di CPU). Image CUDA dipakai supaya driver dan `NVIDIA_DRIVER_CAPABILITIES=video,graphics` tersedia; gl tetap `swangle` supaya stabil.
- **Build image tidak bisa dilakukan di mesin lokal** (kernel memblokir pemetaan subuid) maupun di dalam pod (seccomp memblokir `unshare`). Runner GitHub adalah jalur yang jalan.
