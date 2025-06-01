FROM alpine:latest

ARG  DOCKER_SOCKET_ARG=/var/run/docker.sock
ARG  MDNS_LABEL_ARG=docker-mdns.host
ENV  DOCKER_SOCKET=${DOCKER_SOCKET_ARG}
ENV  MDNS_LABEL=${MDNS_LABEL_ARG}

RUN apk add --no-cache bash avahi avahi-tools dbus docker-cli jq

RUN cat <<'EOF' > /entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
MDNS_LABEL="${MDNS_LABEL:-docker-mdns.host}"

docker ps --filter "label=${MDNS_LABEL}" --format '{{.ID}}' | while read -r cid; do
    domain=$(docker inspect --format "{{ index .Config.Labels \"${MDNS_LABEL}\" }}" "$cid")
    ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")

    if [ -n "$domain" ] && [ -n "$ip" ]; then
        echo "Registering $domain with IP $ip"
        avahi-publish -S "$domain" -a "$ip" -e -v
    else
        echo "Skipping container $cid: missing domain or IP"
    fi
done
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 5353/udp
ENTRYPOINT ["/entrypoint.sh"]
