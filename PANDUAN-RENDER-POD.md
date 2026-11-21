# Panduan: render Remotion di pod RunPod

Untuk agent lain (atau kamu sendiri) yang mau merender video Remotion di GPU RunPod.

Sumber angka di dokumen ini: uji nyata di pod (21–22 Nov 2026). Yang belum dijalankan
ditandai di bagian 11 — jangan dianggap terbukti.

Dokumen ini ditulis supaya bisa dibaca sekali lalu dipakai. Kalau cuma sempat baca satu
bagian, baca **bagian 5 (jalur cepat)** lalu **bagian 2 (aturan)**.

---

## 1. Aset yang sudah tersedia

| Hal | Nilai terverifikasi |
| --- | --- |
| Template RunPod | `2r4zu7wvgp` — "Remotion GPU - image sendiri" |
| Image | `ghcr.io/budhis/remotion-runpod-gpu:sha-c52acf7` (digest `sha256:6ffc3ddc…`) |
| Repo sumber | https://github.com/budhis/remotion-runpod-gpu (publik) |
| Paket GHCR | publik — pull anonim `200`, tidak perlu registry auth |
| Isi image | Node 22.23.5, Remotion 4.0.545 (semua paket Remotion + CLI global `remotion`), `three` 0.180.0, `@react-three/fiber` 9.8.2, `d3`, `maplibre-gl`, `tailwindcss`, `lucide-react`; Chrome Headless Shell di `/opt/chrome/.remotion`; ffmpeg; sshd siap saat build |
| Perintah render | `render-gpu <entry> <komposisi> <keluaran.mp4> [opsi]` di `/usr/local/bin/render-gpu` |
| Ukuran image | ±2,3 GB terkompresi / 22 layer |
| Script siklus penuh | `render-pod.sh` (repo yang sama) |
| Hasil acuan | 900 frame 1920×1080 = 57 dtk di A40, 48 dtk di runner 12 core |
| Template lama | `tu34s3a8kh` dan `uupcg5jgy1` sudah dihapus — keduanya kosong (tanpa Node/Chrome) |

`render-pod.sh` mengerjakan seluruh siklus: buat pod → kirim proyek → dependensi →
render → tarik hasil → cek bukan hitam → hapus pod.

---

## 2. Aturan yang tidak boleh dilanggar

1. **Pod harus dihapus di akhir**, dan penghapusan diverifikasi (`runpodctl pod list` kosong). Pod menganggur tetap ditagih.
2. **Jangan pakai tag `latest`.** CI menimpa `latest` setiap push; pod yang restart bisa tiba-tiba memakai image lain. Pakai `sha-…`.
3. **Jangan `--gl=angle`.** Pod tanpa display gagal inisialisasi Vulkan/EGL. `render-gpu` memakai `--gl=swangle` secara default.
4. **Jangan isi `--concurrency` dari `nproc`.** `nproc` melihat core host (32–96) sedangkan cgroup memberi 4–8 core. Remotion menolak dan mati dalam sedetik. Kosongkan — Remotion menghitung sendiri (`4x` di A40, `8x` di RTX 4090 32-core).
5. **Jangan mount volume di `/workspace/remotion-app`.** Itu menutupi ekosistem bawaan image. Volume RunPod ter-mount di `/workspace` dan itu aman; kalau mau subfolder, pakai `/workspace/kerja`.
6. **Jangan simpan template dari pod hasil `apt install`.** "Save Template" tidak memotret filesystem — yang tersimpan hanya referensi image + env + start command. Semua yang perlu ada harus dipanggang di image.
7. **Jangan tulis `npx remotion`.** Bin paket `@remotion/cli` bernama `remotion`; `npx remotion` berakhir `could not determine executable to run`. Pakai `render-gpu` atau `node_modules/.bin/remotion`.
8. **Jangan `json.load()` output `runpodctl pod create --wait`.** Progres SSH ditulis ke stdout sebelum JSON. Ambil dari karakter `{` pertama.

---

## 3. Pilih GPU dan data center

Remotion merender lewat browser — **CPU-bound**. GPU hanya mempercepat compositing
sedikit. Yang menentukan kecepatan: jumlah core CPU yang diberikan cgroup.

Urutan pilihan (harga secure, cek ulang karena berubah terus):

| GPU | Harga | Catatan |
| --- | --- | --- |
| `NVIDIA A40` | $0,59/jam | stok paling stabil (`High`), 4x concurrency |
| `NVIDIA L4` | $0,69/jam | sering `Medium` |
| `NVIDIA GeForce RTX 4090` | $0,34 community / $0,89 secure | termurah, 8x concurrency, tapi community bisa hilang |
| `NVIDIA RTX 6000 Ada` / `L40S` | ±$0,8–1,1/jam | cadangan |

**Kalau memakai network volume, GPU dan data center terikat ke lokasi volume.** Volume
`qbh5x8cmcc` ada di `EU-RO-1`; pod harus di sana juga. Di EU-RO-1 pilihan GPU lebih
mahal dan terbatas — RTX 4090 secure $0,89/jam, padahal community $0,34.

Cek stok sebelum berharap:

```bash
runpodctl gpu list -o json | python3 -c '
import json,sys
for g in json.load(sys.stdin):
    print(g["gpuId"], "secure", g["securePricePerHr"], "| community", g["communityPricePerHr"], "| stok", g["stockStatus"])'
```

Stok `Low` sering berujung `There are no longer any instances available with the
requested specifications`. `GPU_CADANGAN` di `render-pod.sh` mencoba GPU berikutnya
otomatis.

---

## 4. Prasyarat di mesin lokal

```bash
# runpodctl
export PATH=$HOME/.local/bin:$PATH
runpodctl doctor            # membuat/memeriksa kunci di ~/.runpod/ssh/runpodctl-ssh-key
runpodctl user              # memastikan API key aktif, sekalian lihat saldo
```

- `runpodctl doctor` harus melaporkan API key valid dan kunci SSH ada. Tanpa itu pod
  dibuat tapi tidak bisa dimasuki.
- `ssh`, `scp`, `tar`, `ffmpeg`/`ffprobe` dipakai di lokal untuk kirim proyek dan cek hasil.

---

## 5. Jalur cepat: satu perintah

```bash
curl -fsSL https://raw.githubusercontent.com/budhis/remotion-runpod-gpu/main/render-pod.sh -o ~/render-pod.sh
chmod +x ~/render-pod.sh

# render biasa
~/render-pod.sh ~/workspace/projects/<proyek> src/index.tsx <Komposisi>

# render + cache dependensi di network volume
TARUH_VOLUME=qbh5x8cmcc ~/render-pod.sh ~/workspace/projects/<proyek> src/index.tsx <Komposisi>
```

Urutan kerja script:

1. pra-cek lokal: entry ada, kunci SSH ada, disk cukup — gagal **sebelum** menyewa GPU
2. `pod create` dari template `2r4zu7wvgp`, mencoba `GPU` lalu daftar `GPU_CADANGAN`
3. verifikasi di pod: `node -v`, `remotion --version`, `render-gpu` ada, Chrome ada
4. kirim proyek via `tar` lewat SSH — tanpa `node_modules`, `.git`, `out`, video
5. dependensi: `npm ci`, atau dari cache volume (`CACHE HIT`/`CACHE MISS`)
6. `render-gpu <entry> <komposisi> /root/keluaran/….mp4`
7. `ffprobe` di pod → tarik hasil → cek `YAVG` frame tengah > 10 (bukan hitam)
8. **hapus pod** lewat `trap EXIT` — juga saat gagal atau di-Ctrl-C

Hasil: `<proyek>/out-pod/<Komposisi>-<tanggal>.mp4`, log di `out-pod/render-pod.log`.

Variabel yang bisa diatur:

| Variabel | Default | Arti |
| --- | --- | --- |
| `TEMPLATE_ID` | `2r4zu7wvgp` | template RunPod |
| `GPU` | `NVIDIA GeForce RTX 4090` | GPU utama |
| `GPU_CADANGAN` | `L4, RTX 5090, RTX 6000 Ada` | dicoba berurutan kalau utama habis |
| `CLOUD` | `SECURE` | `SECURE` atau `COMMUNITY` |
| `DATA_CENTER` | `EU-RO-1` | dipakai otomatis kalau `TARUH_VOLUME` diisi |
| `TARUH_VOLUME` | (kosong) | id network volume untuk cache `node_modules` |
| `HAPUS_POD` | `1` | `0` = pod dibiarkan hidup untuk debug (hentikan manual!) |
| `RENDER_CRF` | `18` | kualitas H.264 yang diteruskan ke `render-gpu` |

---

## 6. Cache `node_modules` di network volume

Teruji 22 Nov 2026. Cara kerjanya:

- volume ter-mount di `/workspace`
- kunci cache = sha256 `package-lock.json` (atau `package.json` kalau tak ada lock)
- ada → `CACHE HIT`, untar ±10–20 dtk
- tidak ada → `CACHE MISS`, `npm ci`, simpan `node_modules-<kunci>.tar.gz` ke `/workspace/cache/`

| | Pod 1 (`CACHE MISS`) | Pod 2 (`CACHE HIT`) |
| --- | --- | --- |
| Pod siap | 1m24s | **18 detik** |
| Sampai render mulai | 2m02s | **56 detik** |
| Render 150 frame 1080p | 17 dtk | 21 dtk |
| `YAVG` frame tengah | 32,65 | 32,65 (identik) |
| Pod tersisa setelah selesai | 0 | 0 |

Proyek uji: Remotion 4.0.545, 146 paket, `node_modules` 283 MB → tar 67 MB.

Catatan: `runpodctl user` (saldo) **tidak** bergerak dalam hitungan menit karena RunPod
menagih per jam. Jangan pakai selisih saldo untuk menakar biaya per render; pakai
dashboard Billing.

---

## 7. Jalur manual (kalau script tidak dipakai)

```bash
export PATH=$HOME/.local/bin:$PATH

# 1. buat pod — simpan id, ssh.ip, ssh.port
runpodctl pod create --template-id 2r4zu7wvgp \
  --gpu-id "NVIDIA A40" --gpu-count 1 --cloud-type SECURE \
  --container-disk-in-gb 30 --ports 22/tcp \
  --name rk-render-$(date +%m%d%H%M) \
  --wait --wait-for ssh --wait-timeout 8m

runpodctl ssh info <pod-id>
```

Koneksi: `ssh -i ~/.runpod/ssh/runpodctl-ssh-key root@<ip> -p <port>`

Kirim proyek (jalankan di lokal):

```bash
tar -C ~/workspace/projects/<proyek> -czf - \
    --exclude=node_modules --exclude=.git --exclude=out --exclude='*.mp4' . \
  | ssh -i ~/.runpod/ssh/runpodctl-ssh-key root@<ip> -p <port> \
      'mkdir -p /root/kerja && tar -C /root/kerja -xzf -'
```

Render di dalam pod:

```bash
cd /root/kerja
npm ci --no-audit --no-fund                # atau: npm install --legacy-peer-deps
render-gpu src/index.tsx MainComp /root/keluaran/video.mp4
ffprobe -v error -show_entries format=duration,size -show_entries stream=width,height,nb_frames /root/keluaran/video.mp4
```

Tarik hasil, lalu **hapus pod**:

```bash
scp -i ~/.runpod/ssh/runpodctl-ssh-key -P <port> root@<ip>:/root/keluaran/video.mp4 ./
runpodctl pod stop <pod-id> && sleep 12 && runpodctl pod delete <pod-id>
runpodctl pod list          # harus kosong
```

---

## 8. `render-gpu` — referensi

```
render-gpu <entry> <komposisi> <keluaran.mp4> [opsi remotion]

render-gpu src/index.ts MainComp out/video.mp4
render-gpu src/index.ts MainComp out/video.mp4 --crf=15
render-gpu            # tanpa argumen: cetak bantuan, exit 2
```

| Variabel | Default | Arti |
| --- | --- | --- |
| `RENDER_GL` | `swangle` | `angle`, `angle-egl`, `swiftshader`, `vulkan` |
| `RENDER_CRF` | – | kualitas H.264, mis. `18` |
| `RENDER_CONCURRENCY` | – | tab paralel; kosong = otomatis dari cgroup |
| `RENDER_CODE` | – | codec: `h264`, `vp8`, … |
| `RENDER_FRAMES` | – | `0-59` untuk uji cepat |
| `RENDER_GPU_INFO` | `1` | cetak info GPU sebelum render |

Selain memanggil `remotion render`, `render-gpu` juga:

- memilih bin `remotion`: `node_modules/.bin` → global → `npx --package @remotion/cli`
- mencari Chrome di `/opt/chrome/.remotion` kalau `REMOTION_BROWSER_EXECUTABLE` kosong
- membuat folder keluaran
- melaporkan durasi dinding + ukuran berkas

---

## 9. Jebakan yang sudah terbukti

**`REMOTION_BROWSER_EXECUTABLE` hilang di sesi SSH.** Ada di `/proc/1/environ` tapi tidak
terwarisi login shell. Tanpa penanganan Remotion mengunduh Chrome 102 MB tiap kali.
`render-gpu` mencari sendiri; entrypoint image juga menulis `/etc/profile.d/remotion.sh`.

**`nproc` menipu.** Di pod, `nproc` = 32–96 sementara `cpu.max` hanya 4–8 core.

**`node_modules` proyek wajib ada.** Image punya paket lengkap di `/workspace/remotion-app`,
tapi `remotion render` membaca `node_modules` direktorinya sendiri.

**`runpodctl template list` default bukan template milikmu.** Tanpa `--type user`, yang
tampil template resmi/komunitas (10 pertama). Ini yang bikin "3 template saya" terlihat
asing.

**Volume butuh data center sama.** Pod di DC lain tidak mendapat volume.

**Pesan di chat ≠ isi template.** Dua template lama bernama
`remotion-render-l4-node22-chrome157` ternyata kosong. Verifikasi dengan masuk pod, bukan
percaya nama.

---

## 10. Hasil acuan

Uji 21 Nov 2026, pod A40, komposisi `Durasi30`:

```
h264 · 1920x1080 · 30 fps · 900 frame · Concurrency 4x (otomatis)
[render-gpu] selesai dalam 57 detik
ffprobe: 30.000000 dtk, 900 frame, 1,39 MB · YAVG 41.3
```

Runner GitHub 12 core: 48 detik untuk render yang sama → ±16–19 frame/detik.
Di RTX 4090 32 core (150 frame): 17–21 dtk → ±7–9 frame/detik karena komposisi ujinya
lebih berat per frame.

Kalau di podmu di bawah 3 frame/detik: curigai `--concurrency` terisi dari `nproc`, aset
diambil dari jaringan, atau `--gl` bukan `swangle`.

---

## 11. Kalau perlu image baru

```bash
git clone https://github.com/budhis/remotion-runpod-gpu
cd remotion-runpod-gpu
# ubah Dockerfile (mis. REMOTION_VERSION)
git commit -am "naik versi remotion" && git push
# tunggu Actions hijau: langkah 9 render 5 frame, langkah 9b render 900 frame di dalam image
runpodctl template update 2r4zu7wvgp --image ghcr.io/budhis/remotion-runpod-gpu:sha-<commit>
runpodctl template get 2r4zu7wvgp     # baca balik
```

Build pertama ±8–15 menit, berikutnya 2–6 menit berkat cache `type=gha`.

---

## 12. Yang belum terbukti

- Proyek yang butuh paket di luar daftar image (`@remotion/whisper-web`, `cesium`) — perlu `npm install` sendiri, belum dicoba.
- Serverless/queue — image ini untuk **Pod**.
- `--gl=angle` di GPU Blackwell — belum dicoba; `swangle` tetap anjuran.
- `CACHE MISS` susulan saat `package-lock.json` berubah — logikanya ada, belum dijalankan.

Sudah terbukti: pod dari template, verifikasi isi image, kirim proyek, `npm ci`, render,
tarik hasil, cek hitam, hapus pod (2x `EXIT=0`, `pod list` kosong), dan cache volume
`CACHE MISS` → `CACHE HIT`.
