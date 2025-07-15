#!/bin/bash

# ==============================================================================
# Docker Universal Logger - Setup Script
#
# This script installs or removes a systemd service that automatically logs
# all running Docker containers to /var/log/docker/, with log rotation.
# ==============================================================================

# --- Configuration ---
SERVICE_NAME="docker-logger.service"
SCRIPT_NAME="docker-log-daemon.sh"
LOGROTATE_NAME="docker-container-logs"
LOG_DIR="/var/log/docker"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
LOGROTATE_PATH="/etc/logrotate.d/${LOGROTATE_NAME}"

# --- Helper Functions ---

# Function to print messages
echo_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
echo_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

# Function to check for root privileges
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo_error "This script must be run with root privileges. Please use sudo."
        exit 1
    fi
}

# --- Core Logic Functions ---

install_service() {
    echo_info "Starting Docker Logger installation..."
    check_root

    # 1. Check for dependencies
    local missing_deps=()
    command -v docker >/dev/null 2>&1 || missing_deps+=("docker")
    command -v logrotate >/dev/null 2>&1 || missing_deps+=("logrotate")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo_warn "Missing dependencies: ${missing_deps[*]}"
        local installer=""
        if command -v apt-get >/dev/null; then installer="apt-get";
        elif command -v dnf >/dev/null; then installer="dnf";
        elif command -v yum >/dev/null; then installer="yum"; fi

        if [ -n "$installer" ]; then
            read -p "Do you want to try and install them using ${installer}? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sudo $installer install -y "${missing_deps[@]}"
            else
                echo_error "Installation cancelled by user."
                exit 1
            fi
        else
            echo_error "No supported package manager (apt, dnf, yum) found. Please install the missing dependencies manually and re-run."
            exit 1
        fi
    fi

    # 2. Create log directory
    echo_info "Ensuring log directory exists: ${LOG_DIR}"
    mkdir -p "$LOG_DIR"

    # 3. Create the daemon script using a heredoc
    echo_info "Creating daemon script at ${SCRIPT_PATH}"
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
LOG_DIR="/var/log/docker"
SCRIPT_LOG_FILE="${LOG_DIR}/daemon.log"
declare -A logging_pids
declare -A container_start_times

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$SCRIPT_LOG_FILE"
}

archive_log() {
    local container_name=$1
    local log_file="${LOG_DIR}/${container_name}.log"
    if [ -f "$log_file" ]; then
        local timestamp=$(date '+%Y%m%d-%H%M%S')
        local archive_file="${LOG_DIR}/${container_name}-${timestamp}.log.archived"
        log_message "Archiving ${log_file} to ${archive_file}"
        mv "$log_file" "$archive_file"
    fi
}

start_logging_for() {
    local container_name=$1
    log_message "Starting log watch for container: ${container_name}"
    archive_log "$container_name"
    /usr/bin/docker logs -f "$container_name" >> "${LOG_DIR}/${container_name}.log" 2>&1 &
    logging_pids[$container_name]=$!
    container_start_times[$container_name]=$(docker inspect -f '{{.State.StartedAt}}' "$container_name")
}

stop_logging_for() {
    local container_name=$1
    log_message "Stopping log watch for container: ${container_name}"
    if [[ -n "${logging_pids[$container_name]}" ]]; then
        kill "${logging_pids[$container_name]}"
        wait "${logging_pids[$container_name]}" 2>/dev/null
    fi
    archive_log "$container_name"
    unset logging_pids[$container_name]
    unset container_start_times[$container_name]
}

log_message "--- Docker Log Daemon Started ---"
log_message "Performing initial scan of running containers..."
for container_name in $(docker ps --format '{{.Names}}'); do
    archive_log "$container_name"
done

cleanup() {
    log_message "--- Docker Log Daemon Shutting Down ---"
    for name in "${!logging_pids[@]}"; do
        stop_logging_for "$name"
    done
    log_message "--- Shutdown complete ---"
    exit 0
}
trap cleanup SIGINT SIGTERM

while true; do
    mapfile -t running_containers < <(docker ps --format '{{.Names}}')
    for name in "${running_containers[@]}"; do
        if [[ -z "${logging_pids[$name]}" ]]; then
            start_logging_for "$name"
        fi
    done
    for name in "${!logging_pids[@]}"; do
        if ! docker ps -q --filter "name=^${name}$" --filter "status=running" | grep -q .; then
            stop_logging_for "$name"
        else
            current_start_time=$(docker inspect -f '{{.State.StartedAt}}' "$name")
            if [[ "${container_start_times[$name]}" != "$current_start_time" ]]; then
                log_message "Restart detected for container: ${name}. Rotating logs."
                kill "${logging_pids[$name]}"
                wait "${logging_pids[$name]}" 2>/dev/null
                archive_log "$name"
                unset logging_pids[$name]
                unset container_start_times[$name]
            fi
        fi
    done
    sleep 10
done
EOF

    # 4. Make the script executable
    chmod +x "$SCRIPT_PATH"

    # 5. Create the systemd service file
    echo_info "Creating systemd service at ${SERVICE_PATH}"
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Universal Docker Container Logger
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=${SCRIPT_PATH}
KillMode=process
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 6. Create the logrotate configuration
    echo_info "Creating logrotate config at ${LOGROTATE_PATH}"
    cat > "$LOGROTATE_PATH" << EOF
/var/log/docker/*.log {
    size 250M
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

    # 7. Enable and start the service
    echo_info "Reloading systemd and starting service..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    echo_info "Installation complete! Service is now active."
    echo_info "Service log: ${SCRIPT_LOG_FILE}"
    echo_info "Container logs are in: ${LOG_DIR}"
}

remove_service() {
    echo_info "Starting Docker Logger removal..."
    check_root

    # 1. Stop and disable the service
    echo_info "Stopping and disabling systemd service..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1

    # 2. Remove the files
    echo_info "Removing service files..."
    rm -f "$SERVICE_PATH"
    rm -f "$SCRIPT_PATH"
    rm -f "$LOGROTATE_PATH"

    # 3. Reload systemd
    systemctl daemon-reload

    # 4. Ask about the log directory
    echo
    read -p "✨ All done! Would you like to also remove the log directory at ${LOG_DIR}? This cannot be undone! (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo_warn "Removing log directory: ${LOG_DIR}"
        rm -rf "$LOG_DIR"
        echo_info "Log directory removed."
    else
        echo_info "Okay, the log directory has been left intact."
    fi

    echo_info "Uninstallation complete!"
}

# --- Main Execution ---

# Default action is to install if no flags are given
if [ $# -eq 0 ]; then
    install_service
    exit 0
fi

# Parse command-line flags
while [ "$1" != "" ]; do
    case $1 in
        --remove)
            remove_service
            exit 0
            ;;
        *)
            echo_error "Unknown flag: $1"
            echo "Usage: $0 [--remove]"
            exit 1
            ;;
    esac
    shift
done
