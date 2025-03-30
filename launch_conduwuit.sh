#!/bin/bash

# File paths
BASE_PATH="/home/sij/hand_of_morpheus"
TOKEN_FILE="$BASE_PATH/.registration_token"
LOG_FILE="$BASE_PATH/token_refresh.log"
BACKUP_PATH="/home/sij/conduwuit_backup"
ENV_FILE="$BASE_PATH/conduwuit.env"
REPO_PATH="$HOME/workshop/conduwuit"

# Static container settings
CONTAINER_NAME="conduwuit"
CONTAINER_IMAGE="conduwuit:custom"

# Flags
REFRESH_TOKEN=false
SUPER_ADMIN=false
UPDATE=false

# Function to log with timestamp to both file and terminal
log() {
    local message="$(date --iso-8601=seconds) $1"
    echo "$message" >> "$LOG_FILE"  # Write to log file
    echo "$message"                 # Print to terminal
}

# Function to refresh the registration token
refresh_token() {
    NEW_TOKEN=$(openssl rand -hex 3)
    echo -n "$NEW_TOKEN" > "$TOKEN_FILE"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to write new token to $TOKEN_FILE"
        exit 1
    fi
    log "Generated new registration token: $NEW_TOKEN"
}

# Function to update the Docker image
update_docker_image() {
    log "Updating Conduwuit Docker image..."

    # Navigate to the repository directory
    cd "$REPO_PATH" || {
        log "ERROR: Failed to cd into $REPO_PATH"
        exit 1
    }

    # Pull the latest changes
    git pull origin main || {
        log "ERROR: git pull failed"
        exit 1
    }

    # Build the Docker image using Nix
    nix build -L --extra-experimental-features "nix-command flakes" .#oci-image-x86_64-linux-musl-all-features || {
        log "ERROR: nix build failed"
        exit 1
    }

    # Use the result symlink to find the image tarball
    IMAGE_TAR_PATH=$(readlink -f result)
    if [ ! -f "$IMAGE_TAR_PATH" ]; then
        log "ERROR: No image tarball found at $IMAGE_TAR_PATH"
        exit 1
    fi

    # Load the image into Docker and tag it
    docker load < "$IMAGE_TAR_PATH" | awk '/Loaded image:/ { print $3 }' | xargs -I {} docker tag {} "$CONTAINER_IMAGE"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to load and tag Docker image"
        exit 1
    fi
    log "Docker image tagged as $CONTAINER_IMAGE"
}

# Function to restart the container
restart_container() {
    # Stop and remove existing container
    docker stop "$CONTAINER_NAME" 2>/dev/null
    docker rm "$CONTAINER_NAME" 2>/dev/null

    # Base docker run command
    DOCKER_CMD=(docker run -d
        -v "db:/var/lib/conduwuit/"
        -v "${TOKEN_FILE}:/.registration_token:ro"
        -v "${BACKUP_PATH}:/backup"
        --network host
        --name "$CONTAINER_NAME"
        --restart unless-stopped
    )

    # Read the .env file and append CONDUWUIT_ variables as -e options
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            # Skip empty lines and comments
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^CONDUWUIT_ ]]; then
                log "Adding env var: $key=$value"
                DOCKER_CMD+=(-e "$key=$value")
            fi
        done < "$ENV_FILE"
    else
        log "ERROR: Environment file $ENV_FILE not found"
        exit 1
    fi

    # Add RUST_LOG explicitly (since it’s not CONDUWUIT_ prefixed)
    DOCKER_CMD+=(-e RUST_LOG="conduwuit=trace,reqwest=trace,hickory_proto=trace")

    # Add emergency password if --super-admin is set
    if [ "$SUPER_ADMIN" = true ]; then
        EMERGENCY_PASSWORD=$(openssl rand -hex 8)
        log "Setting emergency password to: $EMERGENCY_PASSWORD"
        DOCKER_CMD+=(-e CONDUWUIT_EMERGENCY_PASSWORD="$EMERGENCY_PASSWORD")
    fi

    # Add the image as the last argument
    DOCKER_CMD+=("$CONTAINER_IMAGE")

    # Log the full command for debugging
    log "Docker command: ${DOCKER_CMD[*]}"

    # Execute the docker command
    "${DOCKER_CMD[@]}"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to create new conduwuit container"
        exit 1
    fi

    log "Successfully recreated container \"$CONTAINER_NAME\" with image \"$CONTAINER_IMAGE\"."
    log " - Configuration loaded from $ENV_FILE"
    
    # Log super-admin credentials if applicable
    if [ "$SUPER_ADMIN" = true ]; then
        log "Use the following credentials to log in as the @conduit server user:"
        log "  Username: @conduit:we2.ee"
        log "  Password: $EMERGENCY_PASSWORD"
        log "Once logged in as @conduit:we2.ee, you can invite yourself to the admin room or run admin commands."
    fi
}

# Function to start the Python registration service
start_registration_service() {
    local python_script="$BASE_PATH/registration.py"  # Adjust name if different
    local pid_file="$BASE_PATH/registration.pid"
    local log_file="$BASE_PATH/registration.log"

    if [ ! -f "$python_script" ]; then
        log "ERROR: Python script $python_script not found"
        exit 1
    fi

    # Check if it's already running
    if [ -f "$pid_file" ] && ps -p "$(cat "$pid_file")" > /dev/null 2>&1; then
        log "Registration service already running with PID $(cat "$pid_file")"
    else
        # Start it in the background, redirecting output to a log file
        python3 "$python_script" >> "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$pid_file"
        log "Started registration service with PID $pid"
    fi
}

# Parse command-line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh-token)
            REFRESH_TOKEN=true
            shift
            ;;
        --super-admin)
            SUPER_ADMIN=true
            shift
            ;;
        --update)
            UPDATE=true
            shift
            ;;
        --start-service)
            START_SERVICE=true
            shift
            ;;
        *)
            log "ERROR: Unknown option: $1"
            echo "Usage: $0 [--refresh-token] [--super-admin] [--update]"
            exit 1
            ;;
    esac
done

# Execute based on flags
if [ "$UPDATE" = true ]; then
    update_docker_image
fi
if [ "$REFRESH_TOKEN" = true ]; then
    refresh_token
fi
restart_container
if [ "$START_SERVICE" = true ] || [ "$1" = "@reboot" ]; then  # Run on explicit flag or cron @reboot
    start_registration_service
fi

exit 0
