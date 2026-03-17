#!/bin/bash
# =============================================================================
# WireGuard Watchdog for Unraid 7.2.x
# =============================================================================
# Monitors WireGuard handshake freshness and restarts only when stale.
# Designed for use with Unraid's VPN Manager / User Scripts plugin.
#
# Recommended schedule: Run every 5–10 minutes via User Scripts (cron).
# Cron example (every 5 min): */5 * * * *
#
# HOW IT WORKS:
#   - Reads the last handshake time from `wg show`
#   - If the handshake is older than MAX_HANDSHAKE_AGE_SECONDS, it restarts
#   - If no handshake has ever occurred (tunnel just came up), it waits
#   - Logs all activity with timestamps to a log file
# =============================================================================

# --- Configuration -----------------------------------------------------------

# WireGuard interface name as configured in Unraid VPN Manager
# Check: Settings > VPN Manager, look at the interface name (usually wg0)
WG_INTERFACE="wg1"

# How old (in seconds) a handshake can be before the tunnel is considered stale
# WireGuard re-keys every 180s; VPN peers are typically unresponsive after
# ~3 minutes of silence. 300s (5 min) is a safe threshold. Adjust if needed.
MAX_HANDSHAKE_AGE_SECONDS=300   # 5 minutes — change to 3600 for 1 hour

# How long to wait (seconds) between stop and start during a restart
RESTART_DELAY=5

# Log file location (Unraid's /tmp is RAM-based and clears on reboot; use
# /boot/logs/ if you want persistence across reboots)
LOG_FILE="/tmp/wireguard_watchdog.log"

# Maximum log file size in bytes before rotation (default: 1MB)
MAX_LOG_SIZE=1048576

# Set to 1 to also log "tunnel OK" status checks (verbose mode)
VERBOSE=1

# --- End Configuration -------------------------------------------------------

# Timestamp helper
now() { date '+%Y-%m-%d %H:%M:%S'; }

# Log to file and stdout
log() {
    echo "[$(now)] $*" | tee -a "$LOG_FILE"
}

# Rotate log if it exceeds MAX_LOG_SIZE
rotate_log() {
    if [[ -f "$LOG_FILE" && $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -ge $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log "Log rotated (exceeded ${MAX_LOG_SIZE} bytes)."
    fi
}

# Restart WireGuard using Unraid's rc script
restart_wireguard() {
    log ">>> Stopping WireGuard ($WG_INTERFACE)..."
    /etc/rc.d/rc.wireguard stop
    sleep "$RESTART_DELAY"
    log ">>> Starting WireGuard ($WG_INTERFACE)..."
    /etc/rc.d/rc.wireguard start
    log ">>> Restart complete."
}

# =============================================================================
# Main Logic
# =============================================================================

rotate_log

# Verify wg is available
if ! command -v wg &>/dev/null; then
    log "ERROR: 'wg' command not found. Is WireGuard loaded?"
    exit 1
fi

# Check if the interface exists at all
if ! wg show "$WG_INTERFACE" &>/dev/null; then
    log "WARNING: Interface '$WG_INTERFACE' not found. Attempting to start WireGuard..."
    /etc/rc.d/rc.wireguard start
    exit 0
fi

# Get the latest handshake time across all peers (epoch seconds, 0 if none yet)
LATEST_HANDSHAKE=$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null \
    | awk '{print $2}' \
    | sort -n \
    | tail -1)

# If no handshake data at all
if [[ -z "$LATEST_HANDSHAKE" || "$LATEST_HANDSHAKE" == "0" ]]; then
    log "INFO: No handshake recorded yet on $WG_INTERFACE — tunnel may be initialising. Skipping."
    exit 0
fi

CURRENT_TIME=$(date +%s)
HANDSHAKE_AGE=$(( CURRENT_TIME - LATEST_HANDSHAKE ))
HANDSHAKE_AGE_MIN=$(( HANDSHAKE_AGE / 60 ))

if [[ "$HANDSHAKE_AGE" -gt "$MAX_HANDSHAKE_AGE_SECONDS" ]]; then
    log "STALE: Last handshake was ${HANDSHAKE_AGE}s ago (${HANDSHAKE_AGE_MIN} min) — threshold is ${MAX_HANDSHAKE_AGE_SECONDS}s. Restarting."
    restart_wireguard
else
    [[ "$VERBOSE" -eq 1 ]] && log "OK: Last handshake ${HANDSHAKE_AGE}s ago (${HANDSHAKE_AGE_MIN} min). Tunnel is healthy."
fi

exit 0
