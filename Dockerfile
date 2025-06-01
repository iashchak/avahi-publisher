FROM alpine:latest

ARG  DOCKER_SOCKET_ARG=/var/run/docker.sock
ARG  MDNS_LABEL_ARG=docker-mdns.host
ENV  DOCKER_SOCKET=${DOCKER_SOCKET_ARG}
ENV  MDNS_LABEL=${MDNS_LABEL_ARG}

RUN apk add --no-cache bash avahi avahi-tools dbus docker-cli jq

RUN cat <<'EOF' > /entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

log() {
    echo "[avahi-publisher] $@"
}

DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
MDNS_LABEL="${MDNS_LABEL:-docker-mdns.host}"

log "Ensuring /run/dbus directory exists with correct permissions..."
if [ ! -d /run/dbus ]; then
    mkdir -p /run/dbus
fi
chown messagebus:messagebus /run/dbus

log "Starting dbus-daemon..."
dbus-daemon --system &
sleep 1 # Wait for dbus to be ready
log "dbus-daemon started."

log "Starting avahi-daemon..."
avahi-daemon --daemonize --no-chroot
log "avahi-daemon started."

log "Checking for Docker socket at $DOCKER_SOCKET..."
if [ ! -S "$DOCKER_SOCKET" ]; then
    log "ERROR: Docker socket not found at $DOCKER_SOCKET"
    exit 1
fi

log "Listing containers with label: $MDNS_LABEL"
docker ps --filter "label=${MDNS_LABEL}" --format '{{.ID}}' | while read -r cid; do
    log "Inspecting container $cid"
    domain=$(docker inspect --format "{{ index .Config.Labels \"${MDNS_LABEL}\" }}" "$cid")
    ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")

    log "Container $cid: domain='$domain', ip='$ip'"

    if [ -n "$domain" ] && [ -n "$ip" ]; then
        log "Registering $domain with IP $ip"
        avahi-publish -S "$domain" "$ip"
    else
        log "Skipping container $cid: missing domain or IP"
    fi
done

log "All containers processed."
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 5353/udp
ENTRYPOINT ["/entrypoint.sh"]
