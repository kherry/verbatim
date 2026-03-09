# ── Base image ─────────────────────────────────────────────────────────────
# nvidia/cuda base for GPU access by WhisperX
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# ── System deps ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3-pip \
    ffmpeg \
    nginx \
    supervisor \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Make python3.11 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
 && update-alternatives --install /usr/bin/python  python  /usr/bin/python3.11 1

# ── Install WhisperX ───────────────────────────────────────────────────────
# WhisperX requires torch; install CPU-only torch first to avoid pulling in
# the huge CUDA torch wheel (the CUDA runtime is already on the base image).
# Users who need GPU-accelerated WhisperX can switch to the CUDA torch wheel.
RUN pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir whisperx

# ── App dependencies ───────────────────────────────────────────────────────
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Copy application ───────────────────────────────────────────────────────
COPY . .

# Create storage directories (will be volume-mounted in production)
RUN mkdir -p storage/tmp

# ── nginx config ───────────────────────────────────────────────────────────
COPY nginx/nginx.conf /etc/nginx/nginx.conf
# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default

# ── supervisord config ─────────────────────────────────────────────────────
COPY supervisord.conf /etc/supervisor/conf.d/transcriber.conf

# ── Ports ──────────────────────────────────────────────────────────────────
EXPOSE 80

# ── Entrypoint ─────────────────────────────────────────────────────────────
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
