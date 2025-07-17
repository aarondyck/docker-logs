# Docker Universal Logger v0.20

A robust, self-managing logging service for Linux systems running Docker. This service automatically captures, rotates, and archives the logs for all running Docker containers, making it an ideal "set-it-and-forget-it" solution for server monitoring and debugging.

This version introduces container-specific log folders and a powerful exclusion management system.

## ✨ Project Purpose

The primary goal of this project is to provide a persistent and intelligent logging system for Docker containers. By default, `docker logs` are ephemeral or can become difficult to manage. This service addresses that by:

* **Automatically Detecting Containers:** It continuously scans for new or stopped containers.
* **Persistent Logging:** It saves the real-time output of every container to a dedicated file within its own subfolder (e.g., `/var/log/docker/tautulli/tautulli.log`).
* **Intelligent Log Archiving:** It creates timestamped archives of logs whenever a container stops, restarts, or when the service itself is restarted, ensuring no log data is ever overwritten or lost between sessions.
* **Automatic Log Rotation:** It uses `logrotate` to manage log file sizes, preventing them from consuming excessive disk space.
* **Container Exclusion:** It allows you to specify containers that should be ignored by the logger via a simple management script or configuration file.

## ⚙️ How It Works (Methodology)

The service is comprised of four core components that work together:

1.  **The Installation Script (`install_logger.sh`):** An all-in-one script that handles the complete setup and removal of all other components. It also creates the `manage-exclusions.sh` utility.

2.  **The Daemon Script (`docker-log-daemon.sh`):** This is a smart Bash script that runs continuously in the background. It acts as the brain of the operation, using `docker inspect` to maintain a list of running containers and their state. It respects the exclusion list found in `/etc/docker-logger/exclude.list`.

3.  **The Exclusion Manager (`manage-exclusions.sh`):** A user-friendly command-line tool installed to `/usr/local/bin` that allows you to easily view, add, remove, or interactively configure the container exclusion list.

4.  **The `systemd` Unit (`docker-logger.service`):** A standard `systemd` service file that manages the daemon script, ensuring it starts on boot and restarts if it ever fails.

5.  **The `logrotate` Configuration:** A configuration file that automatically rotates logs in each container's subfolder once they reach 250MB.

## 🚀 Installation

An all-in-one installation script is provided to set up the entire service.

1.  **Clone the repository or download `install_logger.sh`** to your server.

2.  **Make the script executable:**
    ```bash
    chmod +x install_logger.sh
    ```

3.  **Run the script with `sudo`:**
    ```bash
    # For a default installation
    sudo ./install_logger.sh

    # Or, run with flags to configure exclusions during installation
    sudo ./install_logger.sh --interactive
    sudo ./install_logger.sh --exclude portainer
    ```

The script will automatically:
* Check for required dependencies (`docker`, `logrotate`) and offer to install them.
* Create all necessary directories and files.
* Create the daemon script and the `manage-exclusions.sh` utility.
* Create the `systemd` unit and `logrotate` configuration.
* Reload `systemd` and start the service.

## 🗑️ Removal

To completely remove the service and all its components, run the installation script with the `--remove` flag.

```bash
sudo ./install_logger.sh --remove
```

The removal process will stop the service, delete all component files, and prompt you to confirm if you also want to delete the `/var/log/docker` directory.

## 📄 Usage and Log Management

### Managing Exclusions with `manage-exclusions.sh`

After installation, you can use the `manage-exclusions.sh` command to control which containers are logged.

**Usage:** `sudo manage-exclusions.sh [command]`

**Examples:**

* **Display the help menu:**
    ```bash
    sudo manage-exclusions.sh --help
    ```

* **Add a running container named `portainer` to the exclusion list:**
    ```bash
    sudo manage-exclusions.sh --add portainer
    ```

* **Remove `portainer` from the exclusion list so it gets logged again:**
    ```bash
    sudo manage-exclusions.sh --remove portainer
    ```

* **Run a fully interactive session to configure all containers:**
    This is the easiest way to set up your exclusion list. It will ask you about every running container and also check for stale entries in your current list.
    ```bash
    sudo manage-exclusions.sh --interactive
    ```

* **Clear the entire exclusion list, causing all containers to be logged:**
    ```bash
    sudo manage-exclusions.sh --clear
    ```

### Accessing the Logs

All logs are stored in the `/var/log/docker/` directory, organized into subfolders for each container.

* **Daemon Log:** To see what the logger itself is doing:
    ```bash
    tail -f /var/log/docker/daemon.log
    ```

* **Active Container Logs:** To watch the live logs for a specific container (e.g., `tautulli`):
    ```bash
    tail -f /var/log/docker/tautulli/tautulli.log
    ```

* **Archived Logs:** When a container stops or restarts, its log is archived within its folder (e.g., `/var/log/docker/tautulli/tautulli-20250717-084500.log.archived`).

* **Rotated Logs:** Logs rotated by `logrotate` due to size will be named with a number and compressed within their respective folders (e.g., `/var/log/docker/tautulli/tautulli.log.1`, `/var/log/docker/tautulli/tautulli.log.2.gz`).
