# =================================================
# Aptible Tunnel Service with Terminal UI
# Provides PostgreSQL and Redis tunnels via socat
# =================================================
# Force amd64 platform - aptible CLI only supports amd64
# ARM users (M1/M2 Macs) will run via QEMU emulation
FROM --platform=linux/amd64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
ENV APTIBLE_HOME=/root/.aptible
ENV PATH=/opt/aptible-toolbelt/bin:$PATH

# -------------------------------------------------
# Install runtime dependencies
# -------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    bash \
    socat \
    netcat-openbsd \
    iproute2 \
    procps \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------
# Install ttyd
# -------------------------------------------------
RUN curl -L https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd \
 && chmod +x /usr/local/bin/ttyd

# -------------------------------------------------
# Install Aptible Toolbelt
# -------------------------------------------------
COPY aptible/aptible-toolbelt_latest_debian-9_amd64.deb /tmp/aptible-toolbelt.deb

RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/aptible-toolbelt.deb \
 && rm -f /tmp/aptible-toolbelt.deb \
 && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------
# Create rootless user aptible
# -------------------------------------------------
RUN useradd -m -s /bin/bash aptible \
 && mkdir -p /home/aptible/.aptible \
 && cp -r /etc/skel/. /home/aptible/ \
 && chown -R aptible:aptible /home/aptible

# -------------------------------------------------
# Terminal UI Setup (removed custom server)
# -------------------------------------------------

# -------------------------------------------------
# Startup script and configuration
# -------------------------------------------------
COPY aptible/startup.sh /usr/local/bin/startup.sh
RUN sed -i 's/\r$//' /usr/local/bin/startup.sh \
 && chmod +x /usr/local/bin/startup.sh

# -------------------------------------------------
# Ports: 3000 (Terminal UI), 54321 (PG), 51597 (Redis)
# -------------------------------------------------
EXPOSE 3000 54321 51597

CMD ["/usr/local/bin/startup.sh"]
