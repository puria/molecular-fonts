# Headless Fontra server for molecular-fonts, suitable for Coolify

FROM node:22-bookworm

# System deps
RUN apt-get update && apt-get install -y \
    python3 python3-venv python3-pip python3-dev \
    build-essential git \
 && rm -rf /var/lib/apt/lists/*

# Get Fontra source
WORKDIR /opt
RUN git clone --depth=1 https://github.com/fontra/fontra.git
WORKDIR /opt/fontra

# Python venv + deps (with skia-pathops pin fix)
RUN python3 -m venv /opt/fontra/.venv \
 && /opt/fontra/.venv/bin/pip install --upgrade pip \
 && sed -i 's/skia-pathops==0\.8\.0\.post2/skia-pathops==0.9.0/' requirements.txt \
 && /opt/fontra/.venv/bin/pip install -r requirements.txt \
 && /opt/fontra/.venv/bin/pip install .

# Put Fontra CLI on PATH
ENV PATH="/opt/fontra/.venv/bin:${PATH}"

# Copy this repo (molecular-fonts) into /fonts
WORKDIR /fonts
COPY . /fonts

EXPOSE 8000

# Honour $PORT from Coolify, default to 8000 locally
CMD ["sh", "-c", "fontra --host 0.0.0.0 filesystem /fonts"]

