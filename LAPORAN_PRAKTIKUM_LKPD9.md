# LAPORAN HASIL PRAKTIKUM
## LKPD 9: CI/CD Docker Swarm dengan GitHub Actions

---

### A. IDENTITAS PRAKTIKUM
* **Mata Pelajaran / Modul :** DevOps Engineer
* **Topik Praktikum         :** Otomasi CI/CD pada Docker Swarm Multi-Node Menggunakan GitHub Actions
* **Nama Siswa              :** Fendy Ramadhani
* **Kelas / Kelompok        :** DevOps Engineer / Cloud & Containerization
* **Tanggal Pelaksanaan     :** 15 Oktober 2026
* **Lingkungan Praktik      :** AWS Academy Learner Lab (Region `us-east-1`), Docker Swarm, GitHub Actions, Docker Hub

---

### B. PROLOG & TUJUAN PRAKTIKUM

#### 1. Praktikum Ini Untuk Apa?
Pada praktik sebelumnya (LKPD 8), kita membangun cluster Docker Swarm 3-node dan 1 database terpisah secara manual menggunakan metode *bind mount* dan *git pull*. Cara manual tersebut memiliki kelemahan besar: pengembang harus login ke setiap server secara manual untuk menarik kode terbaru, rentan kesalahan konfigurasi, dan tidak ada otomatisasi pengujian.

Di **LKPD 9** ini, kita membangun alur **CI/CD (Continuous Integration & Continuous Delivery/Deployment)** modern:
1. **Continuous Integration (CI):** Setiap kali pengembang melakukan `git push` ke branch `main`, GitHub Actions secara otomatis memeriksa integritas sintaks kode PHP, mem-build Docker Image, dan mengunggahnya (*push*) ke Docker Hub dengan tag `latest` dan tag SHA commit.
2. **Continuous Delivery/Deployment (CD):** Setelah image berhasil dibuat, GitHub Actions langsung menghubungi node manager cluster Docker Swarm via SSH, lalu memerintahkan Swarm untuk melakukan *rolling update* secara bertahap tanpa membuat aplikasi mati (*zero downtime*).
3. **Pemisahan Konfigurasi (Docker Config):** File sensitif seperti `config/db.php` (berisi password dan IP database) tidak dimasukkan ke dalam Docker Image atau GitHub, melainkan disuntikkan secara aman via **Docker Config** Swarm.

#### 2. Tujuan Pembelajaran
* Mampu membuat `Dockerfile` dan `.dockerignore` untuk mengemas aplikasi PHP-Nginx ke dalam Docker Image.
* Mampu merancang workflow GitHub Actions (`.github/workflows/deploy.yml`) untuk otomatisasi build dan push image ke Docker Hub.
* Mampu mengamankan kredensial database dari repository menggunakan fitur Docker Config.
* Mampu mengotomatiskan *rolling update* dan mempraktikkan proses *rollback* bila terjadi kegagalan rilis.

---

### C. TOPOLOGI & INFRASTRUKTUR CLUSTER

Infrastruktur dideploy di atas AWS Academy menggunakan Terraform:

| Node | Peran | IP Private | IP Public | Keterangan |
| :--- | :--- | :--- | :--- | :--- |
| **manager** | Swarm Manager (Leader) | `172.31.5.5` | `44.200.202.109` | Endpoint SSH GitHub Actions & Swarm Orchestrator |
| **worker1** | Swarm Worker | `172.31.14.42` | `44.192.131.175` | Menjalankan replika service web |
| **worker2** | Swarm Worker | `172.31.13.170` | `44.222.181.165` | Menjalankan replika service web |
| **db** | Database Server | `172.31.14.9` | `18.213.151.58` | Menjalankan MariaDB 11.8 (di luar Swarm) |

* **Port yang digunakan:**
  - `8080`: Akses Web Aplikasi Kantin (Public / Routing Mesh).
  - `3306`: Akses database MariaDB (Private / inter-node Security Group).
  - `22`: SSH remote access (diizinkan untuk runner GitHub Actions).
  - `2377, 7946, 4789`: Jalur internal komunikasi dan overlay cluster Docker Swarm.

---

### D. LANGKAH-LANGKAH PRAKTIKUM & PENJELASAN PERINTAH

#### Tahap 1: Persiapan Repository & Kredensial CI/CD
1. **Fork Repository Aplikasi:**
   - Melakukan fork repository `https://github.com/paknux/appKantin` ke akun GitHub pribadi: `https://github.com/fendyramadhani9-cloud/appKantin`.
2. **Membuat Kunci SSH Deploy di Manager:**
   Perintah dijalankan di terminal node manager:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/gha_deploy -N ""
   ```
   * *Penjelasan:* Membuat sepasang kunci kriptografi ED25519 baru khusus untuk deployment tanpa passphrase (`-N ""`).
   ```bash
   cat ~/.ssh/gha_deploy.pub >> ~/.ssh/authorized_keys
   ```
   * *Penjelasan:* Memasukkan kunci publik ke daftar akses yang diizinkan agar GitHub Actions dapat masuk ke server via SSH.
3. **Mengatur GitHub Repository Secrets:**
   Pada repository fork GitHub (`Settings` -> `Secrets and variables` -> `Actions`), didaftarkan 4 secret:
   - `DOCKERHUB_USERNAME`: Username Docker Hub (`fendyramadhani`).
   - `DOCKERHUB_TOKEN`: Personal Access Token dari Docker Hub berizin *Read & Write*.
   - `SSH_HOST`: IP Publik node manager (`44.200.202.109`).
   - `SSH_PRIVATE_KEY`: Kunci privat dari file `~/.ssh/gha_deploy` di node manager.

---

#### Tahap 2: Pengemasan Aplikasi (Dockerfile & .dockerignore)
Di root direktori repository dibuat dua berkas:

1. **`Dockerfile`**:
   ```dockerfile
   FROM trafex/php-nginx
   COPY --chown=nobody . /var/www/html/
   ```
   * *Penjelasan:* Menggunakan base image `trafex/php-nginx` yang ringan berbasis Alpine Linux (sudah include Nginx & PHP-FPM). Baris kedua menyalin seluruh source code aplikasi ke direktori web server dengan hak milik user `nobody` (user non-root bawaan image).

2. **`.dockerignore`**:
   ```text
   .git
   .github
   README.md
   ```
   * *Penjelasan:* Mencegah file history git, file workflow GitHub, dan dokumentasi ikut terbungkus ke dalam image agar ukuran image lebih kecil dan efisien.

---

#### Tahap 3: Pemisahan Konfigurasi Rahasia (Docker Config)
Dijalankan di terminal node manager:
```bash
docker config create kantin_db_php /home/ubuntu/appKantin/config/db.php
```
* *Penjelasan:* Menyimpan konfigurasi koneksi database lokal yang berisi IP private DB (`172.31.14.9`) dan password ke dalam manajemen config internal Swarm dengan nama `kantin_db_php`.

```bash
docker service create --name kantin \
  --replicas 3 -p 8080:8080 \
  --config source=kantin_db_php,target=/var/www/html/config/db.php \
  fendyramadhani/appkantin:latest
```
* *Penjelasan:* Membuat service Swarm bernama `kantin` dengan 3 replika container, mempublikasikan port 8080, dan menyuntikkan Docker config `kantin_db_php` langsung ke path `/var/www/html/config/db.php` di dalam container saat runtime.

---

#### Tahap 4: Membangun Workflow CI/CD (`deploy.yml`)
Dibuat file `.github/workflows/deploy.yml`:
```yaml
name: CI-CD appKantin

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Tugas 3 (Tantangan): Pengecekan Sintaks PHP Otomatis
      - name: Setup PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.2'

      - name: Cek sintaks PHP
        run: |
          for f in $(find . -name '*.php'); do
            php -l "$f" || exit 1
          done

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ secrets.DOCKERHUB_USERNAME }}/appkantin:latest
            ${{ secrets.DOCKERHUB_USERNAME }}/appkantin:${{ github.sha }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to Docker Swarm via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ubuntu
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            docker service update \
              --image ${{ secrets.DOCKERHUB_USERNAME }}/appkantin:${{ github.sha }} \
              --update-parallelism 1 --update-delay 10s \
              kantin
```
* *Penjelasan Bagian Penting:*
  - `on: push: branches: [main]`: Pipeline terpicu otomatis setiap ada perubahan yang di-push ke branch main.
  - `php -l "$f" || exit 1`: Memeriksa ada/tidaknya kesalahan sintaks PHP (*linting*). Jika ada file yang error, pipeline build langsung dibatalkan.
  - `tags: ...:${{ github.sha }}`: Memberikan tag SHA commit unik ke image yang dibuat.
  - `needs: build`: Job `deploy` hanya akan dieksekusi jika job `build` berstatus sukses.
  - `--update-parallelism 1 --update-delay 10s`: Menjalankan *rolling update* mengganti container satu per satu dengan jeda 10 detik agar layanan tidak terputus.

---

#### Tahap 5: Rilis Fitur Baru & Uji Rolling Update (Tugas 1)
1. Menambahkan baris penampil hostname di [footer.php](file:///d:/Projects/DevOps/Scripts/am/appKantin-fork/footer.php):
   ```php
   <small>Dilayani oleh: <?= gethostname() ?></small>
   ```
2. Commit dan push ke repository GitHub.
3. Mengamati proses rolling update di manager:
   ```bash
   docker service ps kantin
   ```
   * *Hasil:* Terlihat replika lama berstatus *Shutdown* secara bertahap dan digantikan replika baru berstatus *Running* dengan image bertag commit SHA (`fendyramadhani/appkantin:0e0a093...`).

---

#### Tahap 6: Pengujian Fitur Rollback (Langkah 7 & Tugas 2)
Jika versi baru memiliki masalah setelah dideploy, kita dapat mengembalikan versi aplikasi secara instan ke versi sebelumnya:
```bash
docker service rollback kantin
```
* *Penjelasan:* Swarm secara otomatis mengembalikan image dan konfigurasi service ke versi sebelum eksekusi update terakhir.
```bash
docker service inspect kantin --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
```
* *Penjelasan:* Menampilkan tag image aktif untuk memastikan container sudah kembali ke versi stabil sebelumnya.

---

### E. HASIL PENGUJIAN & VERIFIKASI

1. **GitHub Actions Run:**
   - Run ID: `#38681202867` (Status: **Completed - Success / Hijau**)
   - Job `build` berhasil melewati syntax check PHP dan sukses push ke Docker Hub.
   - Job `deploy` berhasil login SSH ke AWS dan mengeksekusi service update.

2. **Docker Hub Image:**
   - Repository: `fendyramadhani/appkantin`
   - Tag terverifikasi: `latest` dan `0e0a093497a107450b7d08ede80d2e1d77f6648b`.

3. **Verifikasi Web Browser & Load Balancing Routing Mesh:**
   Pengujian HTTP request berulang ke port 8080 menghasilkan response rotasi container yang berbeda:
   - Request 1: `Dilayani oleh: cc9fba68c788` (Node Manager)
   - Request 2: `Dilayani oleh: 1c65264e36cb` (Node Worker 1)
   - Request 3: `Dilayani oleh: 081f310b865c` (Node Worker 2)
   - Data menu, meja, dan database tetap tersinkronisasi utuh karena terhubung ke container MariaDB di instance `172.31.14.9`.

---

### F. JAWABAN PERTANYAAN REFLEKSI

1. **Mengapa image diberi tag `github.sha` dan tidak hanya `latest`? Apa yang sulit dilakukan jika hanya ada `latest`?**
   * *Jawaban:* Tag `github.sha` memberikan identifikasi versi yang unik (*immutable*) dan terikat langsung pada riwayat commit Git. Jika hanya memakai `latest`, Docker Swarm tidak bisa mendeteksi perubahan image karena nama tag-nya selalu sama, dan sangat sulit melakukan **rollback** yang presisi ke versi commit tertentu jika versi baru mengalami kegagalan/bug.

2. **Bandingkan cara ini dengan bind mount + git pull terjadwal (LKPD 8). Sebutkan 2 keunggulan dan 1 kekurangan memakai image!**
   * *Keunggulan Memakai Image:*
     1. **Lingkungan Konsisten & Portabel:** Kode, dependensi, dan web server dibundel utuh, mengeliminasi masalah perbedaan konfigurasi antar server (*it works on my machine*).
     2. **Automasi Tanpa Login:** Node-node Swarm secara otomatis menarik image terbaru dari registry terpusat tanpa perlu login dan melakukan `git pull` manual di setiap mesin.
   * *Kekurangan Memakai Image:*
     1. Waktu proses rilis (*pipeline duration*) sedikit lebih lambat dibanding bind mount karena ada tahap build image dan upload/download image melalui jaringan internet.

3. **Mengapa `config/db.php` disimpan sebagai Docker config dan tidak dimasukkan ke image atau repository?**
   * *Jawaban:* Demi alasan keamanan (*security best practice* - prinsip 12-factor app). Menyimpan file yang berisi IP private dan password database di dalam image publik atau GitHub berisiko kebocoran data rahasia. Docker config memungkinkan file rahasia diinjeksi langsung ke container hanya saat runtime tanpa meninggalkan jejak di kode sumber image.

4. **Apa risiko membuka port 22 untuk `0.0.0.0/0`? Bagaimana self-hosted runner pada node manager dapat menghindari kebutuhan ini?**
   * *Risiko:* Membuka port 22 ke internet publik meningkatkan risiko serangan brute-force SSH, credential stuffing, dan eksploitasi celah keamanan server.
   * *Solusi Self-Hosted Runner:* Jika runner GitHub Actions dipasang langsung di dalam node manager (*self-hosted*), runner yang akan berinisiatif menghubungi server GitHub (*outbound connection*). Dengan demikian, port 22 di Security Group AWS tidak perlu dibuka ke publik sama sekali (*0.0.0.0/0*).

5. **Jelaskan mana yang disebut CI dan mana yang CD pada workflow ini!**
   * *CI (Continuous Integration):* Bagian job `build` pada file workflow. Tahap ini otomatis memeriksa sintaks kode (`php -l`), mem-build Docker Image, dan mem-push image ke Docker Hub saat ada perubahan kode.
   * *CD (Continuous Delivery/Deployment):* Bagian job `deploy` pada file workflow. Tahap ini otomatis masuk ke server manager via SSH dan memperbarui service Swarm secara bergantian (*rolling update*) hingga aplikasi live di production.

6. **Pada Tugas 2, mengapa swarm tidak otomatis rollback walaupun aplikasi rusak? Apa yang perlu ditambahkan agar kerusakan terdeteksi sebelum atau saat deploy?**
   * *Jawaban:* Docker Swarm hanya memantau apakah proses utama container (Nginx/PHP-FPM) tetap berjalan (*exit code 0*). Jika kode PHP mengalami syntax error atau fatal error tetapi server web Nginx masih aktif mengembalikan respon HTTP 500, Swarm mengira container tetap berjalan normal.
   * *Yang Perlu Ditambahkan:* Menambahkan konfigurasi **Docker Healthcheck** (misal instruksi `HEALTHCHECK --interval=5s CMD curl -f http://localhost:8080/ || exit 1`) di Dockerfile atau service Swarm, sehingga jika web server mengembalikan error, Swarm menandai container tersebut *unhealthy* dan otomatis mengeksekusi rollback.

---

### G. KENDALA YANG DIALAMI & CARA MENGATASINYA

1. **Sesi Kredensial AWS Academy Expired (`ExpiredToken`):**
   * *Kendala:* Kredensial AWS Academy Learner Lab memiliki batas waktu aktif, sehingga sempat terjadi penolakan autentikasi saat eksekusi CLI.
   * *Solusi:* Melakukan siklus **End Lab** lalu **Start Lab** kembali di konsol AWS Academy, kemudian mengambil kredensial terbaru dari *AWS Details*.
2. **Port 8080 Bentrok dengan Service Lama:**
   * *Kendala:* Saat membuat service `kantin`, muncul error `port '8080' is already in use by service 'kantin_web'` sisa praktikum LKPD 8.
   * *Solusi:* Menghapus stack lama dengan perintah `docker stack rm kantin` dan `docker service rm kantin_web` sebelum membuat service baru.

---

### H. KESIMPULAN

Praktikum LKPD 9 ini berhasil membuktikan bahwa penerapan pipeline **CI/CD menggunakan GitHub Actions** yang terintegrasi dengan **Docker Hub** dan **Docker Swarm** mampu memangkas waktu proses rilis aplikasi dari yang sebelumnya manual dan rawan kesalahan menjadi sepenuhnya otomatis, terstandarisasi, dan aman. Penggunaan **Docker Config** menjamin kredensial rahasia tetap aman, sementara fitur **Rolling Update** dan **Rollback** memberikan keandalan tinggi (*High Availability*) bagi layanan aplikasi web di lingkungan produksi.
