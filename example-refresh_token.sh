#!/bin/bash

# File paths - adjust these to your system
BASE_PATH="/path/to/hand_of_morpheus"          # Base directory for token and logs
TOKEN_FILE="$BASE_PATH/.registration_token"     # Where the token will be stored
LOG_FILE="$BASE_PATH/token_refresh.log"         # Where script logs will be written
BACKUP_PATH="/path/to/conduwuit_backup"         # Where database backups will be stored

# Server configuration
SERVER_DOMAIN="your.domain"                     # Your Matrix server's domain
HOST_PORT=8448                                  # Port on your host machine
CONTAINER_PORT=6167                             # Port inside the container
CONTAINER_NAME="conduwuit"                      # Name for the Docker container
CONTAINER_IMAGE="ghcr.io/girlbossceo/conduwuit:v0.5.0-rc2-e5049cae4a3890dc5f61ead53281f23b36bf4c97"

# Auto-join room configuration - rooms users automatically join upon registration
AUTO_JOIN_ROOMS="[\"#community:$SERVER_DOMAIN\",\"#welcome:$SERVER_DOMAIN\"]"

# Function to log with timestamp
log() {
    echo "$(date --iso-8601=seconds) $1" >> "$LOG_FILE"
}

# Generate new token (6 random hex characters)
NEW_TOKEN=$(openssl rand -hex 3)

# Write new token to file without newline
echo -n "$NEW_TOKEN" > "$TOKEN_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to write new token to $TOKEN_FILE"
    exit 1
fi

log "Generated new registration token"

# Recreate conduwuit container
docker stop $CONTAINER_NAME
docker rm $CONTAINER_NAME

docker run -d \
  -p 127.0.0.1:${HOST_PORT}:${CONTAINER_PORT} \
  -v db:/var/lib/conduwuit/ \
  -v "${TOKEN_FILE}:/.registration_token:ro" \
  -v "${BACKUP_PATH}:/backup" \
  -e CONDUWUIT_SERVER_NAME="$SERVER_DOMAIN" \
  -e CONDUWUIT_DATABASE_PATH="/var/lib/conduwuit/conduwuit.db" \
  -e CONDUWUIT_DATABASE_BACKUP_PATH="/backup" \
  -e CONDUWUIT_ALLOW_REGISTRATION=true \
  -e CONDUWUIT_REGISTRATION_TOKEN_FILE="/.registration_token" \
  -e CONDUWUIT_PORT=$CONTAINER_PORT \
  -e CONDUWUIT_ADDRESS="0.0.0.0" \
  -e CONDUWUIT_NEW_USER_DISPLAYNAME_SUFFIX="" \
  -e CONDUWUIT_ALLOW_PUBLIC_ROOM_DIRECTORY_OVER_FEDERATION=true \
  -e CONDUWUIT_ALLOW_PUBLIC_ROOM_DIRECTORY_WITHOUT_AUTH=true \
  -e CONDUWUIT_ALLOW_FEDERATION=true \
  -e CONDUWUIT_AUTO_JOIN_ROOMS="$AUTO_JOIN_ROOMS" \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  $CONTAINER_IMAGE

if [ $? -ne 0 ]; then
    log "ERROR: Failed to create new conduwuit container"
    exit 1
fi

log "Successfully recreated conduwuit container with new token"
