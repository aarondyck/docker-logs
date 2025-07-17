#!/bin/bash

# ==============================================================================
# Docker Universal Logger - Setup Script v0.20
#
# This script installs or removes a systemd service that automatically logs
# all running Docker containers to individual subfolders in /var/log/docker/,
# with support for excluding specific containers.
# ==============================================================================

# --- Configuration ---
SERVICE_NAME="docker-logger.service"
DAEMON_SCRIPT_NAME="docker-log-daemon.sh"
MANAGE_SCRIPT_NAME="manage-exclusions.sh"
LOGROTATE_NAME="docker-container-logs"
CONFIG_DIR="/etc/docker-logger"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"
LOG_DIR="/var/log/docker"
DAEMON_SCRIPT_PATH="/usr/local/bin/${DAEMON_SCRIPT_NAME}"
MANAGE_SCRIPT_PATH="/usr/local/bin/${MANAGE_SCRIPT_NAME}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
LOGROTATE_PATH="/etc/logrotate.d/${LOGROTATE_NAME}"

# --- Helper Functions ---

# Function to print messages with colors
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

show_help() {
    echo "Docker Universal Logger - Installer and Configurator"
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  (no command)          Installs the docker-logger service."
    echo "  --interactive, -i     Runs interactive setup, then installs the service."
    echo "  --exclude, -x <name>  Adds a container to the exclusion list, then installs."
    echo "  --remove              Stops and completely removes the service and its components."
    echo "  --help, -h            Displays this help message."
    echo
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

    # 2. Create config and log directories and files
    echo_info "Ensuring config and log directories exist..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    touch "$EXCLUDE_FILE"

    # 3. Create the daemon script
    echo_info "Creating daemon script at ${DAEMON_SCRIPT_PATH}"
    cat > "$DAEMON_SCRIPT_PATH" << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/docker-logger"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"
LOG_DIR="/var/log/docker"
DAEMON_LOG_FILE="${LOG_DIR}/daemon.log"
declare -A logging_pids
declare -A container_start_times

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$DAEMON_LOG_FILE"
}

archive_log() {
    local container_name=$1
    local container_log_dir="${LOG_DIR}/${container_name}"
    local log_file="${container_log_dir}/${container_name}.log"
    if [ -f "$log_file" ]; then
        local timestamp=$(date '+%Y%m%d-%H%M%S')
        local archive_file="${container_log_dir}/${container_name}-${timestamp}.log.archived"
        log_message "Archiving ${log_file} to ${archive_file}"
        mv "$log_file" "$archive_file"
    fi
}

start_logging_for() {
    local container_name=$1
    local container_log_dir="${LOG_DIR}/${container_name}"
    mkdir -p "$container_log_dir"
    log_message "Starting log watch for container: ${container_name}"
    archive_log "$container_name"
    /usr/bin/docker logs -f "$container_name" >> "${container_log_dir}/${container_name}.log" 2>&1 &
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
    declare -A excluded_containers
    if [ -f "$EXCLUDE_FILE" ]; then
        while read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^\s*# ]] || [[ -z "$line" ]] && continue
            excluded_containers["$line"]=1
        done < "$EXCLUDE_FILE"
    fi
    mapfile -t running_containers < <(docker ps --format '{{.Names}}')
    for name in "${running_containers[@]}"; do
        if [[ -n "${excluded_containers[$name]}" ]]; then
            continue
        fi
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
    chmod +x "$DAEMON_SCRIPT_PATH"

    # 4. Create the management script
    echo_info "Creating management script at ${MANAGE_SCRIPT_PATH}"
    cat > "$MANAGE_SCRIPT_PATH" << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/docker-logger"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"
echo_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
echo_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }
check_root() { if [[ "$EUID" -ne 0 ]]; then echo_error "This script must be run with root privileges. Please use sudo."; exit 1; fi; }
show_help() {
    echo "Docker Universal Logger - Exclusion Manager"
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  -a, --add <name>      Add a running container to the exclusion list."
    echo "  -r, --remove <name>   Remove a container from the exclusion list."
    echo "  -c, --clear           Clear all entries from the exclusion list."
    echo "  -i, --interactive     Interactively configure the entire exclusion list."
    echo "  -h, --help            Displays this help message."
    echo
}
add_container() {
    local container_name=$1; echo_info "Attempting to add '${container_name}' to exclusion list...";
    if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then echo_error "Container '${container_name}' is not currently running. Only running containers can be excluded."; exit 1; fi
    if grep -qxF "$container_name" "$EXCLUDE_FILE"; then echo_warn "Container '${container_name}' is already in the exclusion list. No action taken."; else echo "$container_name" >> "$EXCLUDE_FILE"; echo_info "Successfully added '${container_name}' to the exclusion list."; fi
}
remove_container() {
    local container_name=$1; echo_info "Attempting to remove '${container_name}' from exclusion list...";
    if ! grep -qxF "$container_name" "$EXCLUDE_FILE"; then echo_error "Container '${container_name}' was not found in the exclusion list."; exit 1; fi
    grep -vxF "$container_name" "$EXCLUDE_FILE" > "${EXCLUDE_FILE}.tmp" && mv "${EXCLUDE_FILE}.tmp" "$EXCLUDE_FILE"; echo_info "Successfully removed '${container_name}' from the exclusion list.";
    if docker ps -q --filter "name=^${container_name}$" | grep -q .; then echo_warn "Container '${container_name}' is running and will now be logged on the next cycle."; fi
}
clear_exclusions() {
    echo_warn "This will remove all entries from the exclusion list and cause all containers to be logged."; read -p "Are you sure you want to clear the entire list? (y/n) " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then > "$EXCLUDE_FILE"; echo_info "Exclusion list has been cleared."; else echo_info "Operation cancelled."; fi
}
interactive_mode() {
    echo_info "Entering interactive exclusion configuration..."; local temp_exclude_file=$(mktemp); mapfile -t running_containers < <(docker ps --format '{{.Names}}'); mapfile -t current_exclusions < <(cat "$EXCLUDE_FILE" 2>/dev/null);
    echo_info "Checking for non-running containers in the exclusion list...";
    for excluded_name in "${current_exclusions[@]}"; do
        is_running=false; for running_name in "${running_containers[@]}"; do if [[ "$excluded_name" == "$running_name" ]]; then is_running=true; break; fi; done
        if ! $is_running; then read -p "Container '${excluded_name}' is not running. Keep it in the exclusion list? (y/n) " -n 1 -r; echo; if [[ $REPLY =~ ^[Yy]$ ]]; then echo "$excluded_name" >> "$temp_exclude_file"; echo_info "Keeping '${excluded_name}' in the list."; else echo_warn "Removing stale entry '${excluded_name}' from the list."; fi; fi
    done
    echo_info "Configuring currently running containers...";
    for name in "${running_containers[@]}"; do
        is_excluded=false; if grep -qxF "$name" "$EXCLUDE_FILE"; then is_excluded=true; fi; prompt_text="Log container '${name}'?"; default_answer="Y/n"; if $is_excluded; then prompt_text+=" (currently excluded)"; default_answer="y/N"; fi
        read -p "$prompt_text ($default_answer) " -n 1 -r; echo
        if [[ $REPLY =~ ^[Nn]$ ]] || ([[ -z $REPLY ]] && $is_excluded); then grep -qxF "$name" "$temp_exclude_file" || echo "$name" >> "$temp_exclude_file"; echo_info "'${name}' will be excluded."; else echo_info "'${name}' will be logged."; fi
    done
    mv "$temp_exclude_file" "$EXCLUDE_FILE"; echo_info "Exclusion list has been updated based on your selections."
}
check_root; mkdir -p "$CONFIG_DIR"; touch "$EXCLUDE_FILE";
if [ $# -eq 0 ]; then show_help; exit 1; fi
while (( "$#" )); do
    case "$1" in
        -h|--help) show_help; exit 0;;
        -a|--add) if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then add_container "$2"; shift 2; else echo_error "Error: Argument for $1 is missing" >&2; exit 1; fi;;
        -r|--remove) if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then remove_container "$2"; shift 2; else echo_error "Error: Argument for $1 is missing" >&2; exit 1; fi;;
        -c|--clear) clear_exclusions; shift;;
        -i|--interactive) interactive_mode; shift;;
        *) echo_error "Unknown flag: $1"; show_help; exit 1;;
    esac
done
echo_info "Operation complete. The logger will apply changes on its next cycle (within 10 seconds)."
EOF
    chmod +x "$MANAGE_SCRIPT_PATH"

    # 5. Create the systemd service file
    echo_info "Creating systemd service at ${SERVICE_PATH}"
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Universal Docker Container Logger
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=${DAEMON_SCRIPT_PATH}
KillMode=process
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 6. Create the logrotate configuration
    echo_info "Creating logrotate config at ${LOGROTATE_PATH}"
    cat > "$LOGROTATE_PATH" << EOF
# This rule applies to all .log files inside container-specific subdirectories
/var/log/docker/*/*.log {
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

    echo_info "✅ Installation complete! Service is now active."
    echo_info "Use '${MANAGE_SCRIPT_NAME}' to manage container exclusions."
}

remove_service() {
    echo_info "Starting Docker Logger removal..."
    check_root

    echo_info "Stopping and disabling systemd service..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1

    echo_info "Removing service files..."
    rm -f "$SERVICE_PATH"
    rm -f "$DAEMON_SCRIPT_PATH"
    rm -f "$MANAGE_SCRIPT_PATH"
    rm -f "$LOGROTATE_PATH"
    rm -rf "$CONFIG_DIR"

    systemctl daemon-reload

    echo
    read -p "✨ Hip hip hooray, the service is away! Would you also like to clear out all the logs at ${LOG_DIR}? This can't be undone! (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo_warn "Removing log directory: ${LOG_DIR}"
        rm -rf "$LOG_DIR"
        echo_info "Log directory has been tidied up!"
    else
        echo_info "Okay, the log directory has been left for your viewing pleasure."
    fi

    echo_info "✅ Uninstallation complete!"
}

add_to_exclude_list() {
    local container_name=$1
    if grep -qxF "$container_name" "$EXCLUDE_FILE"; then
        echo_warn "Container '$container_name' is already on the exclusion list."
    else
        echo_info "Adding '$container_name' to the exclusion list."
        echo "$container_name" >> "$EXCLUDE_FILE"
    fi
}

interactive_exclude_mode() {
    echo_info "Entering interactive exclusion mode..."
    check_root
    
    mkdir -p "$CONFIG_DIR"
    touch "$EXCLUDE_FILE"

    mapfile -t running_containers < <(docker ps --format '{{.Names}}')

    if [ ${#running_containers[@]} -eq 0 ]; then
        echo_info "No running containers found to configure."
        return
    fi

    echo "For each container, decide if you want to log it. Not logging it will add it to the exclude list."
    
    for name in "${running_containers[@]}"; do
        read -p "Log container '${name}'? (Y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            add_to_exclude_list "$name"
        else
            echo_info "Container '${name}' will be logged."
        fi
    done

    echo_info "Interactive session complete."
}


# --- Main Execution ---

# Handle help and removal as priority actions that exit immediately.
for arg in "$@"; do
  if [ "$arg" == "--help" ] || [ "$arg" == "-h" ]; then
    show_help
    exit 0
  fi
  if [ "$arg" == "--remove" ]; then
    remove_service
    exit 0
  fi
done

# If we're not removing, we'll be installing.
# First, process any flags that modify the configuration.
if [ $# -gt 0 ]; then
    while (( "$#" )); do
        case "$1" in
            -i|--interactive)
                interactive_exclude_mode
                shift
                ;;
            -x|--exclude)
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    check_root
                    mkdir -p "$CONFIG_DIR"
                    touch "$EXCLUDE_FILE"
                    add_to_exclude_list "$2"
                    shift 2
                else
                    echo_error "Error: Argument for $1 is missing" >&2
                    exit 1
                fi
                ;;
            *)
                echo_error "Unknown flag: $1"
                show_help
                exit 1
                ;;
        esac
    done
fi

# Finally, run the installation.
install_service
