#!/bin/bash
# ak-ssh-keys.sh
# Fetch SSH key for a user from Authentik and cache it locally.
# Must print the key(s) to stdout for SSH.

USER="$1"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/$USER"

# Helper to log messages (goes to log only)
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $USER: $1" >> "$LOG_FILE"
}

log "lookup requested"

# Try fetching from Authentik API
KEY=$(curl -s -H "Authorization: Bearer $API_TOKEN" \
    "$AUTHENTIK_URL/api/v3/core/users/?username=$USER" \
    | jq -r '.results[0].attributes.sshPublicKey // empty')

if [ -n "$KEY" ]; then
    # Save key to cache for offline use
    echo "$KEY" > "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
    log "key fetched from Authentik"
    # Print key to stdout for SSH
    echo "$KEY"
    exit 0
fi

# If no key from Authentik, try cached key
if [ -f "$CACHE_FILE" ]; then
    log "using cached key"
    cat "$CACHE_FILE"
    exit 0
fi

# No key found anywhere
log "no key found"
exit 1