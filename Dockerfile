FROM alpine:latest

RUN apk add --no-cache bash avahi dbus docker-cli jq

RUN cat << EOF > /entrypoint.sh
#!/bin/bash
DOCKER_SOCKET="/var/run/docker.sock"
MDNS_LABEL="docker-mdns.host"

docker ps --filter "label=$MDNS_LABEL" --format "{{.ID}}" | while read -r cid; do
    domain=$(docker inspect --format '{{ index .Config.Labels "$MDNS_LABEL" }}' "$cid")
    ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
    if [ -n "$domain" ] && [ -n "$ip" ]; then
        echo "Registering $domain with IP $ip"
        avahi-publish -s "$domain" "" "$ip"
    else
        echo "Skipping container $cid: missing domain or IP"
    fi
done
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 5353/udp
ENTRYPOINT ["/entrypoint.sh"]
