#!/bin/bash

# ==============================================================================
# Docker Universal Logger - Exclusion Management Script
#
# This script provides a user-friendly interface to add, remove, and manage
# the container exclusion list for the docker-logger service.
# ==============================================================================

# --- Configuration ---
CONFIG_DIR="/etc/docker-logger"
EXCLUDE_FILE="${CONFIG_DIR}/exclude.list"

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

# --- Core Logic Functions ---

add_container() {
    local container_name=$1
    echo_info "Attempting to add '${container_name}' to exclusion list..."

    # Validate that the container is actually running
    if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then
        echo_error "Container '${container_name}' is not currently running. Only running containers can be excluded."
        exit 1
    fi

    # Validate that the container isn't already excluded
    if grep -qxF "$container_name" "$EXCLUDE_FILE"; then
        echo_warn "Container '${container_name}' is already in the exclusion list. No action taken."
    else
        echo "$container_name" >> "$EXCLUDE_FILE"
        echo_info "Successfully added '${container_name}' to the exclusion list."
    fi
}

remove_container() {
    local container_name=$1
    echo_info "Attempting to remove '${container_name}' from exclusion list..."

    # Validate that the container is actually on the list
    if ! grep -qxF "$container_name" "$EXCLUDE_FILE"; then
        echo_error "Container '${container_name}' was not found in the exclusion list."
        exit 1
    fi

    # Remove the container using a temporary file
    grep -vxF "$container_name" "$EXCLUDE_FILE" > "${EXCLUDE_FILE}.tmp" && mv "${EXCLUDE_FILE}.tmp" "$EXCLUDE_FILE"
    echo_info "Successfully removed '${container_name}' from the exclusion list."

    # If the container is still running, notify the user it will now be logged
    if docker ps -q --filter "name=^${container_name}$" | grep -q .; then
        echo_warn "Container '${container_name}' is running and will now be logged on the next cycle."
    fi
}

clear_exclusions() {
    echo_warn "This will remove all entries from the exclusion list and cause all containers to be logged."
    read -p "Are you sure you want to clear the entire list? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Truncate the file to zero size
        > "$EXCLUDE_FILE"
        echo_info "Exclusion list has been cleared."
    else
        echo_info "Operation cancelled."
    fi
}

interactive_mode() {
    echo_info "Entering interactive exclusion configuration..."
    
    local temp_exclude_file=$(mktemp)
    
    # Get lists of running and currently excluded containers
    mapfile -t running_containers < <(docker ps --format '{{.Names}}')
    mapfile -t current_exclusions < <(cat "$EXCLUDE_FILE" 2>/dev/null)

    # Check for stale entries in the exclusion list
    echo_info "Checking for non-running containers in the exclusion list..."
    for excluded_name in "${current_exclusions[@]}"; do
        is_running=false
        for running_name in "${running_containers[@]}"; do
            if [[ "$excluded_name" == "$running_name" ]]; then
                is_running=true
                break
            fi
        done

        if ! $is_running; then
            read -p "Container '${excluded_name}' is not running. Keep it in the exclusion list? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "$excluded_name" >> "$temp_exclude_file"
                echo_info "Keeping '${excluded_name}' in the list."
            else
                echo_warn "Removing stale entry '${excluded_name}' from the list."
            fi
        fi
    done

    # Go through running containers to add/remove from the new list
    echo_info "Configuring currently running containers..."
    for name in "${running_containers[@]}"; do
        is_excluded=false
        if grep -qxF "$name" "$EXCLUDE_FILE"; then
            is_excluded=true
        fi

        prompt_text="Log container '${name}'?"
        default_answer="Y/n"
        if $is_excluded; then
            prompt_text+=" (currently excluded)"
            default_answer="y/N"
        fi

        read -p "$prompt_text ($default_answer) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]] || ([[ -z $REPLY ]] && $is_excluded); then
             # Add to temp file if not already there from the stale check
            grep -qxF "$name" "$temp_exclude_file" || echo "$name" >> "$temp_exclude_file"
            echo_info "'${name}' will be excluded."
        else
            echo_info "'${name}' will be logged."
        fi
    done

    # Replace the old exclusion list with the new one
    mv "$temp_exclude_file" "$EXCLUDE_FILE"
    echo_info "Exclusion list has been updated based on your selections."
}

# --- Main Execution ---

check_root

# Ensure config directory and file exist before any operation
mkdir -p "$CONFIG_DIR"
touch "$EXCLUDE_FILE"

if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

while (( "$#" )); do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -a|--add)
            if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                add_container "$2"
                shift 2
            else
                echo_error "Error: Argument for $1 is missing" >&2
                exit 1
            fi
            ;;
        -r|--remove)
            if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                remove_container "$2"
                shift 2
            else
                echo_error "Error: Argument for $1 is missing" >&2
                exit 1
            fi
            ;;
        -c|--clear)
            clear_exclusions
            shift
            ;;
        -i|--interactive)
            interactive_mode
            shift
            ;;
        *)
            echo_error "Unknown flag: $1"
            show_help
            exit 1
            ;;
    esac
done

echo_info "Operation complete. The logger will apply changes on its next cycle (within 10 seconds)."
