#!/usr/bin/env bash
# Downloads training logs from a remote host.
# Improved for generality: Supports any host and optional custom path.
# Updates: Saves to timestamped directory inside a parent folder.

set -euo pipefail

# --- Configuration ---
# Default local parent directory for saving logs
DEFAULT_LOCAL_PARENT_DIR="$HOME/framework/server_logs"
# Default remote path if not specified as the 2nd argument
DEFAULT_REMOTE_LOG_DIR="/home/zhw/framework/server_logs/drone_racer/logs"
# SSH key path for authentication (SSH密钥路径)
# Default: ~/.ssh/id_ed25519
DEFAULT_SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
SSH_KEY_PATH="${SSH_KEY_PATH:-$DEFAULT_SSH_KEY_PATH}"

usage() {
  # Use ${0##*/} to get the script name only
  SCRIPT_NAME="${0##*/}"

  cat <<EOF
Usage: $SCRIPT_NAME <HOST> [REMOTE_PATH]

Arguments:
  HOST          The hostname or IP address.
  REMOTE_PATH   (Optional) Path to logs on remote.
                Defaults to: $DEFAULT_REMOTE_LOG_DIR

Environment Variables:
  SSH_KEY_PATH            SSH key path for authentication
                          Default: \$HOME/.ssh/id_ed25519
  DEFAULT_LOCAL_PARENT_DIR
                          Default local parent directory for saving logs
                          Default: \$HOME/server_logs
  DEFAULT_REMOTE_LOG_DIR  Default remote path if not specified as 2nd argument
                          Default: $DEFAULT_REMOTE_LOG_DIR

Example:
  $SCRIPT_NAME rec-server
  $SCRIPT_NAME rec-server /tmp/custom_logs
  SSH_KEY_PATH=/custom/key $SCRIPT_NAME rec-server
EOF
  exit 1
}

# --- Argument Parsing ---
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi

if [ "$#" -lt 1 ]; then
  echo "Error: Target host is required." >&2
  usage
fi

TARGET_HOST="$1"
# Use the second argument as path if provided, otherwise use default
REMOTE_LOG_DIR="${2:-$DEFAULT_REMOTE_LOG_DIR}"

# --- Dependency Check ---
for cmd in ssh rsync date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Execution ---

echo "Checking remote directory on ${TARGET_HOST}..."

# Check if remote directory exists
if ! ssh -i "$SSH_KEY_PATH" "$TARGET_HOST" "[ -d '$REMOTE_LOG_DIR' ]"; then
  echo "Error: Remote directory '$REMOTE_LOG_DIR' not found on ${TARGET_HOST}." >&2
  exit 1
fi

# 1. Generate Timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 2. Construct LOCAL_DIR based on Parent Dir, Host, and Timestamp
# Structure: ~/server_logs/<HOST>_<TIMESTAMP>
# This keeps logs organized by download session.
LOCAL_DIR="${DEFAULT_LOCAL_PARENT_DIR}/${TARGET_HOST}_${TIMESTAMP}"

echo "Downloading logs from '${TARGET_HOST}:${REMOTE_LOG_DIR}' to '${LOCAL_DIR}'..."

# Safety: Prepare local directory
# Removed 'rm -rf' because we are creating a unique timestamped directory every time.
mkdir -p "$LOCAL_DIR"

# Run rsync
# Added -h for human-readable numbers
# Using -e flag to specify SSH with custom key
rsync -avzh -e "ssh -i '$SSH_KEY_PATH'" "$TARGET_HOST:${REMOTE_LOG_DIR}/" "$LOCAL_DIR/"

echo "-----------------------------------------------------"
echo "Success! Logs downloaded to: $LOCAL_DIR"
