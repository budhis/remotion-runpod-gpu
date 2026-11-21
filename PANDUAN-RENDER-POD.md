# Panduan: render Remotion di pod RunPod

Untuk agent lain (atau kamu sendiri) yang mau merender video Remotion di GPU RunPod. Semua angka dan perintah di sini **sudah dijalankan di pod nyata pada 21 Nov 2026** — yang belum diuji ditandai jelas.

## 1. Aset yang sudah tersedia

| Hal | Nilai terverifikasi |
| --- | --- |
| Template RunPod | `2r4zu7wvgp` — "Remotion GPU - image sendiri" |
| Image | `ghcr.io/budhis/remotion-runpod-gpu:sha-c52acf7` (digest `sha256:6ffc3ddc…`) |
| Repo sumber | https://github.com/budhis/remotion-runpod-gpu (publik) |
| Paket GHCR | publik — pull anonim `200`, tidak perlu registry auth |
| Isi image | Node 22.23.5, Remotion 4.0.545 (semua paket + CLI global `remotion`), Chrome Headless Shell di `/opt/chrome/.remotion`, ffmpeg, sshd siap saat build |
| Perintah render | `render-gpu <entry> <komposisi> <keluaran.mp4> [opsi]` di `/usr/local/bin/render-gpu` |
| Ukuran image | ±2,3 GB terkompresi / 22 layer |
| Biaya terbukti | 900 frame 1920×1080 → 57 detik render; total pod 12 menit = **$0,089** (A40 $0,59/jam) |

Script pembantu: `render-pod.sh` di repo — membuat pod, mengirim proyek, render, tarik hasil, hapus pod, semuanya otomatis.

## 2. Aturan yang tidak boleh dilanggar

1. **Pod harus dihapus di akhir**, dan penghapusan harus **diverifikasi** (`runpodctl pod list` kosong). Pod menganggur tetap ditagih.
2. **Jangan pakai `latest`** untuk image template. CI menimpa `latest` setiap push, jadi pod yang restart bisa tiba-tiba memakai image lain. Pakai tag `sha-…`.
3. **Jangan `--gl=angle`.** Di pod tanpa display, ANGLE gagal inisialisasi Vulkan/EGL. `render-gpu` sudah memakai `--gl=swangle`.
4. **Jangan `nproc`** untuk `--concurrency`. Di pod, `nproc` melihat core host (96–112) sedangkan cgroup hanya memberi 9–23. Remotion menolak nilai lebih besar dari yang terlihat cgroup dan mati dalam sedetik. Biarkan kosong — Remotion menghitung sendiri (di uji: `4x` otomatis).
5. **Jangan mount network volume di `/workspace`.** Image memasang ekosistem di `/workspace/remotion-app`; mount di situ akan menutupinya. Pakai `/workspace/...` subfolder, mis. `--volume-mount-path /workspace/kerja`.
6. **Jangan simpan template dari pod yang sudah di-`apt install`.** "Save Template" tidak memotret filesystem. Itu sebabnya dua template lama `remotion-render-l4-node22-chrome157(-v2)` kosong (tidak ada Node, tidak ada Chrome). Semua yang perlu ada di image, bukan di pod.
7. **Jangan tulis `npx remotion`.** Bin paket `@remotion/cli` bernama `remotion`; `npx remotion` berakhir `could not determine executable to run`. Pakai `render-gpu`, atau `node_modules/.bin/remotion`.

## 3. Pilih GPU

A40 bukan yang termurah, tapi satu-satunya yang stoknya `High` saat panduan ini ditulis. GPU murah sering `Low`/kosong dan `pod create` dibalas `There are no longer any instances available with the requested specifications`.

Urutan masuk akal untuk render Remotion (CPU-bound, GPU tidak wajib):

1. `NVIDIA A40` (secure, $0,59/jam) — stok paling stabil
2. `NVIDIA L4` (secure, $0,69/jam) — sering `Medium`
3. `NVIDIA GeForce RTX 4090` (community, $0,34/jam) — termurah yang biasanya ada, tapi community bisa hilang kapan saja
4. Cadangan: `RTX 6000 Ada`, `L40S`, `RTX A5000`

Remotion merender lewat browser, jadi GPU hanya mempercepat compositing sedikit. Perbedaan 4090 vs A40 untuk komposisi 2D kecil — tidak signifikan. Yang benar-benar menentukan kecepatan: jumlah core CPU.

## 4. Jalur cepat: satu perintah

```bash
# salin script dulu kalau belum ada
curl -fsSL https://raw.githubusercontent.com/budhis/remotion-runpod-gpu/main/render-pod.sh -o ~/render-pod.sh
chmod +x ~/render-pod.sh

~/render-pod.sh ~/workspace/projects/skala-alam-semesta src/index.tsx SkalaLangit
```

Yang dilakukan script:

1. pra-cek lokal (entry ada, kunci SSH ada, disk cukup) — gagal sebelum menyewa GPU
2. `pod create` dari template `2r4zu7wvgp`, dengan daftar GPU cadangan
3. verifikasi di pod: `node -v`, `remotion --version`, `render-gpu` ada, Chrome ada
4. kirim proyek via `tar` lewat SSH (tanpa `node_modules`, `.git`, `out`, video)
5. `npm ci` (atau `npm install` kalau tak ada lockfile)
6. `render-gpu <entry> <komposisi> /root/keluaran/….mp4`
7. `ffprobe` di pod, tarik hasil, cek `YAVG` frame tengah > 10 (bukan hitam)
8. **hapus pod** lewat `trap EXIT` — termasuk kalau script gagal atau di-Ctrl-C

Hasil: `<proyek>/out-pod/<komposisi>-<tanggal>.mp4`, log di `out-pod/render-pod.log`.

Kalau mau pod-nya dipertahankan untuk debug: `HAPUS_POD=0 ~/render-pod.sh ...`. **Ingat hentikan manual.**

## 5. Jalur manual (kalau script tidak dipakai)

```bash
export PATH=$HOME/.local/bin:$PATH

# 1. buat pod
runpodctl pod create --template-id 2r4zu7wvgp \
  --gpu-id "NVIDIA A40" --gpu-count 1 --cloud-type SECURE \
  --container-disk-in-gb 30 --ports 22/tcp \
  --name rk-render-$(date +%m%d%H%M) \
  --wait --wait-for ssh --wait-timeout 8m
```

Balasannya memuat `id`, `ssh.ip`, `ssh.port`. Simpan `id` — itu satu-satunya cara menghapusnya nanti. Ambil koneksi:

```bash
runpodctl ssh info <pod-id>
# atau langsung:
ssh -i ~/.runpod/ssh/runpodctl-ssh-key root@<ip> -p <port>
```

Di dalam pod:

```bash
# 2. kirim proyek dari mesin lokal (jalankan di lokal, bukan di pod)
tar -C ~/workspace/projects/proyek -czf - --exclude=node_modules --exclude=.git --exclude=out . \
  | ssh -i ~/.runpod/ssh/runpodctl-ssh-key root@<ip> -p <port> 'mkdir -p /root/kerja && tar -C /root/kerja -xzf -'

# 3. render
cd /root/kerja
npm ci --no-audit --no-fund          # atau npm install --legacy-peer-deps
render-gpu src/index.tsx MainComp /root/keluaran/video.mp4

# 4. tarik hasil (dari lokal)
scp -i ~/.runpod/ssh/runpodctl-ssh-key -P <port> root@<ip>:/root/keluaran/video.mp4 ./

# 5. hapus pod (WAJIB)
runpodctl pod stop <pod-id> && sleep 12 && runpodctl pod delete <pod-id>
runpodctl pod list        # harus kosong
```

## 6. `render-gpu` — cara pakai

```
render-gpu <entry> <komposisi> <keluaran.mp4> [opsi remotion]

render-gpu src/index.ts MainComp out/video.mp4
render-gpu src/index.ts MainComp out/video.mp4 --crf=15 --concurrency=8
render-gpu            # tanpa argumen: cetak bantuan, exit 2
```

Variabel lingkungan:

| Variabel | Default | Arti |
| --- | --- | --- |
| `RENDER_GL` | `swangle` | `angle`, `angle-egl`, `swiftshader`, `vulkan` |
| `RENDER_CRF` | – | kualitas H.264, mis. `18` |
| `RENDER_CONCURRENCY` | – | tab paralel; kosong = otomatis dari cgroup |
| `RENDER_CODE` | – | codec: `h264`, `vp8`, … |
| `RENDER_FRAMES` | – | `0-59` untuk uji cepat |
| `RENDER_GPU_INFO` | `1` | cetak info GPU sebelum render |

Yang dilakukan `render-gpu` selain memanggil `remotion render`:
- memilih bin `remotion` lokal → global → `npx --package @remotion/cli`
- mencari Chrome di `/opt/chrome/.remotion` kalau `REMOTION_BROWSER_EXECUTABLE` kosong (terbukti terjadi di sesi SSH)
- membuat folder keluaran
- melaporkan durasi dinding dan ukuran berkas

## 7. Jebakan yang sudah terbukti

**`REMOTION_BROWSER_EXECUTABLE` hilang di sesi SSH.** Di pod, variabel ini ada di `/proc/1/environ` tapi tidak terwarisi ke login shell. Tanpa penanganan, Remotion mengunduh Chrome 102 MB setiap kali. `render-gpu` (sejak tag `sha-c52acf7`) mencari Chrome sendiri; entrypoint image juga menulis `/etc/profile.d/remotion.sh`.

**`nproc` menipu.** `nproc` = 96 padahal `cpu.max` = 7,65 core. Ini penyebab "render mati dalam 1 detik" yang paling sering terjadi.

**`node_modules` proyek wajib ada.** Image punya paket lengkap di `/workspace/remotion-app`, tapi `remotion render` membaca `node_modules` dari direktori proyek. Tanpa `npm ci`, render gagal "module not found".

**`npm install` di pod bisa lambat (1–3 menit).** Kalau merender berulang dari proyek yang sama, pakai network volume dan taruh cache `node_modules.tar.gz` di sana (lihat `TARUH_VOLUME` di `render-pod.sh`).

**Halaman web RunPod dan CLI bisa beda.** `runpodctl template list` default hanya menampilkan template resmi/komunitas (10 pertama). Template milikmu: `runpodctl template list --type user`.

**Bytecode/aset besar.** Kalau proyek punya aset ratusan MB (`public/frames`, gambar), kirim sekali ke network volume, bukan lewat `tar` setiap render.

## 8. Hasil uji acuan (untuk membandingkan kalau ada yang aneh)

Uji 21 Nov 2026, pod A40:

```
Composition Durasi30 · h264 · 1920x1080 · 30 fps · 900 frame
Concurrency 4x (otomatis dari cgroup)
[render-gpu] selesai dalam 57 detik — /tmp/durasi30.mp4
ffprobe: 30.000000 dtk, 900 frame, 1,39 MB
YAVG frame 450 = 41.3 (isi, bukan hitam)
```

Di runner GitHub (12 core): 48 detik untuk render yang sama. Jadi 900 frame 1080p dengan komposisi ringan ≈ 16–19 frame/detik. Kalau di podmu jauh di bawah 5 frame/detik, biasanya masalahnya `--concurrency` atau aset yang diambil dari jaringan.

## 9. Kalau perlu image baru

```bash
git clone https://github.com/budhis/remotion-runpod-gpu
cd remotion-runpod-gpu
# ubah Dockerfile (mis. naikkan REMOTION_VERSION)
git commit -am "naik versi remotion" && git push
# tunggu Actions hijau — langkah 9 me-render 5 frame, langkah 9b 900 frame di dalam image
runpodctl template update 2r4zu7wvgp --image ghcr.io/budhis/remotion-runpod-gpu:sha-<commit>
runpodctl template get 2r4zu7wvgp     # baca balik, jangan percaya begitu saja
```

Build pertama ±8–15 menit; berikutnya 2–6 menit karena cache `type=gha`.

## 10. Yang belum teruji

- Render proyek yang butuh paket **di luar** daftar image (mis. `@remotion/whisper-web`, Cesium) — perlu `npm install` di proyek, pasti jalan, tapi belum dicoba.
- Network volume sebagai cache `node_modules` (`TARUH_VOLUME`) — logikanya sudah ditulis, belum dijalankan end-to-end.
- Serverless (queue) — image ini untuk **Pod**, bukan endpoint serverless.
- Pod dengan GPU Blackwell untuk `--gl=angle` — belum dicoba; `swangle` tetap yang dianjurkan.
