FROM remnawave/node:3.2.2

COPY geoip.dat /tmp/geoip.dat
COPY geosite.dat /tmp/geosite.dat

RUN set -e; \
    DAT_DIR="$(dirname "$(find / -type f -name geoip.dat 2>/dev/null | head -n 1)")"; \
    if [ -z "$DAT_DIR" ]; then \
        echo "ERROR: geoip.dat not found in base image" >&2; \
        exit 1; \
    fi; \
    cp /tmp/geoip.dat "$DAT_DIR/geoip.dat"; \
    cp /tmp/geosite.dat "$DAT_DIR/geosite.dat"; \
    rm /tmp/geoip.dat /tmp/geosite.dat; \
    echo "dat files updated in: $DAT_DIR"
