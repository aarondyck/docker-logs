Docker Universal Logger
A robust, self-managing logging service for Linux systems running Docker. This service automatically captures, rotates, and archives the logs for all running Docker containers, making it an ideal "set-it-and-forget-it" solution for server monitoring and debugging.

✨ Project Purpose
The primary goal of this project is to provide a persistent and intelligent logging system for Docker containers. By default, docker logs are ephemeral or can become difficult to manage. This service addresses that by:

Automatically Detecting Containers: It continuously scans for new or stopped containers.

Persistent Logging: It saves the real-time output of every container to a dedicated file on the host system.

Intelligent Log Archiving: It creates timestamped archives of logs whenever a container stops, restarts, or when the service itself is restarted, ensuring no log data is ever overwritten or lost between sessions.

Automatic Log Rotation: It uses logrotate to manage log file sizes, preventing them from consuming excessive disk space.

⚙️ How It Works (Methodology)
The service is comprised of three core components that work together:

The Daemon Script (docker-log-daemon.sh):
This is a smart Bash script that runs continuously in the background. It acts as the brain of the operation, using docker inspect to maintain a list of running containers and their state.

It polls Docker every 10 seconds.

When it finds a new container, it starts a background docker logs -f process for it.

It detects container restarts by monitoring their StartedAt timestamp. If a timestamp changes, it archives the old log and begins a new one.

When a container stops, it gracefully terminates the logging process and archives the final log file.

It keeps its own log at /var/log/docker/daemon.log to record its actions.

The systemd Unit (docker-logger.service):
This is a standard systemd service file that manages the daemon script.

It ensures the script starts automatically when the server boots.

It's configured to restart the script automatically if it ever fails.

It depends on the docker.service, so it will only start after Docker is running.

The logrotate Configuration (docker-container-logs):
This is a simple configuration file for the standard Linux logrotate utility.

It monitors all active .log files in /var/log/docker/.

When a log file exceeds 250MB, it rotates it, keeping up to 4 compressed archives.

It uses the copytruncate method, which allows the daemon script to continue writing to the log file without interruption.

🚀 Installation
An all-in-one installation script is provided to set up the entire service.

Clone the repository or download the script to your server.

Make the script executable:

chmod +x install-docker-logger.sh

Run the script with sudo:

sudo ./install-docker-logger.sh

The script will automatically:

Check for required dependencies (docker, logrotate) and offer to install them.

Create the log directory (/var/log/docker/).

Create the daemon script, systemd unit, and logrotate configuration files in their correct locations.

Reload systemd and start the service.

🗑️ Removal
To completely remove the service and all its components, run the installation script with the --remove flag.

sudo ./install-docker-logger.sh --remove

The removal process will:

Stop and disable the systemd service.

Delete the daemon script, systemd unit file, and logrotate configuration file.

Prompt you to confirm if you also want to delete the entire /var/log/docker directory, which contains all the logs captured by the service.

📄 Usage and Accessing Logs
The service runs entirely in the background, but you can interact with it and its logs easily.

Checking Service Status
To check if the logger daemon is running, use systemctl:

sudo systemctl status docker-logger.service

You should see an active (running) status.

Viewing the Logs
All logs are stored in the /var/log/docker/ directory.

Daemon Log: To see what the logger itself is doing (e.g., starting/stopping container watches), view its own log file:

tail -f /var/log/docker/daemon.log

Active Container Logs: To watch the live logs for a specific running container (e.g., tautulli):

tail -f /var/log/docker/tautulli.log

Archived Logs: When a container stops or restarts, its log is archived with a timestamp. You can find these files in the same directory, named like tautulli-20250715-082700.log.archived. You can view them with cat, less, or grep.

Rotated Logs: Logs rotated by logrotate due to size will be named with a number and compressed (e.g., tautulli.log.1, tautulli.log.2.gz).
