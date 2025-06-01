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

# PID file paths based on logs and common locations
DBUS_PID_FILE="/run/dbus/dbus.pid" # As seen in user logs
AVAHI_PID_FILE="/run/avahi-daemon/pid"

cleanup_stale_pid() {
    local pid_file="$1"
    local service_name="$2"
    if [ -f "$pid_file" ]; then
        log "Found PID file for $service_name: $pid_file."
        local pid_val
        pid_val=$(head -n 1 "$pid_file" 2>/dev/null) # Read first line, suppress errors
        # Check if pid_val is a number and if process exists
        if [[ "$pid_val" =~ ^[0-9]+$ ]] && ps -p "$pid_val" > /dev/null 2>&1; then
            log "$service_name (PID $pid_val) appears to be running. Will not remove PID file."
        else
            log "$service_name is not running or PID in file '$pid_val' is invalid/stale. Removing stale PID file: $pid_file"
            rm -f "$pid_file"
        fi
    fi
}

trap_handler() {
    log "Received termination signal. Shutting down daemons..."
    # Stop Avahi first
    if [ -f "$AVAHI_PID_FILE" ]; then
        log "Stopping Avahi daemon (PID $(cat "$AVAHI_PID_FILE" 2>/dev/null || echo "unknown"))..."
        local avahi_pid_val
        avahi_pid_val=$(cat "$AVAHI_PID_FILE" 2>/dev/null)
        if [[ "$avahi_pid_val" =~ ^[0-9]+$ ]]; then
            kill "$avahi_pid_val" || log "Avahi already stopped or kill failed for PID $avahi_pid_val."
        else
            log "Invalid PID in Avahi PID file or file unreadable. Attempting pkill."
            pkill -f avahi-daemon || true
        fi
        # Wait a moment for it to shut down and remove its PID file
        for _ in 1 2 3 4 5; do [ ! -f "$AVAHI_PID_FILE" ] && break; sleep 0.2; done
        rm -f "$AVAHI_PID_FILE" # Clean up PID file if still there
    else
        log "Avahi PID file not found. Attempting pkill."
        pkill -f avahi-daemon || true
    fi

    # Then D-Bus
    if [ -f "$DBUS_PID_FILE" ]; then
        log "Stopping D-Bus daemon (PID $(cat "$DBUS_PID_FILE" 2>/dev/null || echo "unknown"))..."
        local dbus_pid_val
        dbus_pid_val=$(cat "$DBUS_PID_FILE" 2>/dev/null)
        if [[ "$dbus_pid_val" =~ ^[0-9]+$ ]]; then
            kill "$dbus_pid_val" || log "D-Bus already stopped or kill failed for PID $dbus_pid_val."
        else
            log "Invalid PID in D-Bus PID file or file unreadable. Attempting pkill."
            pkill -f dbus-daemon || true
        fi
        for _ in 1 2 3 4 5; do [ ! -f "$DBUS_PID_FILE" ] && break; sleep 0.2; done
        rm -f "$DBUS_PID_FILE"
    else
        log "D-Bus PID file not found. Attempting pkill."
        pkill -f dbus-daemon || true
    fi
    log "Shutdown complete."
    exit 0 # Exit trap handler, which exits the script
}

# Register trap handler
trap 'trap_handler' SIGINT SIGTERM

log "Ensuring /run/dbus directory exists and has correct permissions..."
mkdir -p /run/dbus
chown messagebus:messagebus /run/dbus # As in original script

log "Cleaning up stale PID files if any..."
cleanup_stale_pid "$DBUS_PID_FILE" "dbus-daemon"
# Ensure avahi-daemon run directory exists (it should create /run/avahi-daemon itself)
mkdir -p "$(dirname "$AVAHI_PID_FILE")"
cleanup_stale_pid "$AVAHI_PID_FILE" "avahi-daemon"

log "Starting dbus-daemon..."
dbus-daemon --system & # Runs in background, creates its PID file
log "Waiting for dbus-daemon to settle (1s)..."
sleep 1

log "Starting avahi-daemon..."
avahi-daemon --daemonize --no-chroot # Runs in background, creates its PID file
log "Waiting for avahi-daemon to settle (1s)..."
sleep 1

log "Checking for Docker socket at $DOCKER_SOCKET..."
if [ ! -S "$DOCKER_SOCKET" ]; then
    log "ERROR: Docker socket not found at $DOCKER_SOCKET. Exiting."
    exit 1 # This will trigger set -e and script will terminate
fi

log "Performing mDNS registration for existing containers..."
docker ps --filter "label=${MDNS_LABEL}" --format '{{.ID}} {{.Names}}' | while IFS= read -r line; do
    if [ -z "$line" ]; then
        log "Skipping empty line from docker ps output."
        continue
    fi
    cid=$(echo "$line" | cut -d' ' -f1)
    cname=$(echo "$line" | cut -d' ' -f2-) # Name for logging

    log "Inspecting container $cid ($cname) for mDNS registration..."

    container_info_json=$(docker inspect "$cid")
    if [ -z "$container_info_json" ]; then
        log "WARNING: Failed to inspect container $cid. Skipping."
        continue
    fi

    domain=$(echo "$container_info_json" | jq -r ".[0].Config.Labels[\"${MDNS_LABEL}\"] // \"\"")
    ip=$(echo "$container_info_json" | jq -r '.[0].NetworkSettings.Networks | to_entries | map(.value.IPAddress) | map(select(.!=null and .!="" and .!="0.0.0.0")) | first // ""')

    log "Container $cid ($cname): domain='$domain', ip='$ip'"

    if [ -n "$domain" ] && [ -n "$ip" ]; then
        log "Registering: $domain -> $ip using avahi-publish-address"
        avahi-publish-address "$domain" "$ip" &
        log "avahi-publish-address for $domain -> $ip launched in background."
    else
        log "Skipping container $cid ($cname): missing domain or IP (domain='${domain}', ip='${ip}')"
    fi
done

log "Initial registration process complete."
log "Avahi-publisher will now keep daemons running and records published."
log "Note: This script does not dynamically update for new/stopped containers without a restart or further enhancements."

log "Entering idle mode (infinite sleep) to keep container alive. Use Ctrl+C or docker stop to terminate."
# This loop runs in the background, and `wait` waits for it.
# The trap handler will interrupt the `sleep` and then `exit 0`, causing `wait` to return.
while true; do
  sleep 3600 # Sleep for an hour, or until a signal is received
done &
wait $!

# Script should not reach here due to `wait $!` and trap handler exiting.
log "Exiting entrypoint script unexpectedly."
exit 1 # Should not happen in normal operation
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 5353/udp
ENTRYPOINT ["/entrypoint.sh"]
