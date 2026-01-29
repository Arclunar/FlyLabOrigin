#!/usr/bin/env bash
# Continuously monitors and syncs training logs from remote server.
# Only adds new/updated files, never deletes local files (incremental sync).
# Uses same configuration as transfer_codebase.sh for consistency.

set -uo pipefail  # Removed -e to prevent exit on errors

# --- Configuration ---
# Remote Server Configuration (远端服务器配置)
SERVER_IP="${SERVER_IP:-14.103.52.172}"
REMOTE_USER="${REMOTE_USER:-zhw}"

# Local directory for saving logs (persistent, no timestamp)
LOCAL_LOG_DIR="${LOCAL_LOG_DIR:-$HOME/framework/server_logs}"

# Default remote path
REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-/home/zhw/framework/server_logs}"

# SSH key path for authentication (SSH密钥路径)
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"

# Sync interval in seconds (default: 10 seconds)
SYNC_INTERVAL="${SYNC_INTERVAL:-10}"

# Construct target server from REMOTE_USER and SERVER_IP
TARGET_SERVER="${REMOTE_USER}@${SERVER_IP}"

# --- Colors for output ---
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

log() {
  printf "${COLOR_BLUE}[%s]${COLOR_RESET} %s\n" "$(date '+%H:%M:%S')" "$*"
}

log_success() {
  printf "${COLOR_GREEN}[%s] ✓ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

log_warning() {
  printf "${COLOR_YELLOW}[%s] ⚠ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

log_error() {
  printf "${COLOR_RED}[%s] ✗ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*" >&2
}

usage() {
  SCRIPT_NAME="${0##*/}"
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Continuously syncs training logs from remote server to local directory.
Only adds new/updated files, never deletes local files (incremental sync).

Options:
  -h, --help           Show this help message
  -i, --interval SEC   Sync interval in seconds (default: 10)
  -r, --remote PATH    Remote log directory path
  -l, --local PATH     Local log directory path
  -1, --once           Sync once and exit (no watch mode)

Environment Variables:
  SERVER_IP           Remote server IP (default: 14.103.52.172)
  REMOTE_USER         Remote user (default: zhw)
  SSH_KEY_PATH        SSH key path (default: ~/.ssh/id_rsa.pub)
  REMOTE_LOG_DIR      Remote log directory (default: /home/zhw/framework/server_logs)
  LOCAL_LOG_DIR       Local log directory (default: ~/framework/server_logs)
  SYNC_INTERVAL       Sync interval in seconds (default: 10)

Example:
  $SCRIPT_NAME                        # Start continuous sync with defaults
  $SCRIPT_NAME -i 5                   # Sync every 5 seconds
  $SCRIPT_NAME --once                 # Sync once and exit
  $SCRIPT_NAME -r /custom/path        # Use custom remote path
  SERVER_IP=192.168.1.100 $SCRIPT_NAME

Press Ctrl+C to stop watching.
EOF
  exit 1
}

# --- Argument Parsing ---
WATCH_MODE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    -i|--interval)
      SYNC_INTERVAL="$2"
      shift 2
      ;;
    -r|--remote)
      REMOTE_LOG_DIR="$2"
      shift 2
      ;;
    -l|--local)
      LOCAL_LOG_DIR="$2"
      shift 2
      ;;
    -1|--once)
      WATCH_MODE=false
      shift
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage
      ;;
  esac
done

# --- Dependency Check ---
for cmd in ssh rsync; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command '$cmd' is not installed."
    exit 1
  fi
done

# --- Validate remote directory ---
log "Checking remote directory on ${TARGET_SERVER}..."
if ! ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" "[ -d '$REMOTE_LOG_DIR' ]"; then
  log_error "Remote directory '$REMOTE_LOG_DIR' not found on ${TARGET_SERVER}."
  exit 1
fi
log_success "Remote directory verified"

# --- Prepare local directory ---
mkdir -p "$LOCAL_LOG_DIR"

log "Configuration:"
log "  Remote:         ${TARGET_SERVER}:${REMOTE_LOG_DIR}"
log "  Local:          ${LOCAL_LOG_DIR}"
log "  Sync interval:  ${SYNC_INTERVAL}s"
log "  Watch mode:     ${WATCH_MODE}"
log ""

# --- Sync function ---
sync_logs() {
  # rsync options:
  # -a: archive mode (recursive, preserve permissions, times, etc)
  # -v: verbose
  # -z: compress during transfer
  # -h: human-readable numbers
  # --update: skip files that are newer on the receiver (local)
  # --progress: show progress during transfer
  # --stats: show transfer statistics
  # NO --delete: keep local files even if deleted on remote
  # --chmod=Du+w: ensure directories are writable by user
  
  log "Syncing from ${TARGET_SERVER}:${REMOTE_LOG_DIR}..."
  
  # Capture rsync output
  if rsync -avzh \
    --update \
    --progress \
    --stats \
    --chmod=Du+w \
    -e "ssh -i '$SSH_KEY_PATH'" \
    "$TARGET_SERVER:${REMOTE_LOG_DIR}/" \
    "$LOCAL_LOG_DIR/" 2>&1 | tee /tmp/rsync_output.txt; then
    
    # Fix permissions for any directories that might be owned by root
    # This happens when docker volumes create files as root
    find "$LOCAL_LOG_DIR" -type d ! -user "$(whoami)" -exec chmod u+w {} \; 2>/dev/null || true
    
    # Parse rsync stats to see if anything was transferred
    if grep -q "Number of files transferred: 0" /tmp/rsync_output.txt 2>/dev/null; then
      echo -e "${COLOR_BLUE}[$(date '+%H:%M:%S')]${COLOR_RESET} No changes detected"
    else
      log_success "Sync completed"
    fi
    return 0
  else
    log_error "Sync failed"
    return 1
  fi
}

# --- Cleanup handler ---
cleanup() {
  log ""
  log_warning "Stopping log sync..."
  rm -f /tmp/rsync_output.txt
  exit 0
}

trap cleanup SIGINT SIGTERM

# --- Initial sync ---
log "Starting initial sync..."
sync_logs
log_success "Initial sync completed"
log ""

# --- Watch mode or exit ---
if [ "$WATCH_MODE" = "false" ]; then
  log_success "Single sync completed. Exiting."
  exit 0
fi

log_success "Watching for changes (syncing every ${SYNC_INTERVAL}s)..."
log "Press Ctrl+C to stop"
log ""

# --- Continuous sync loop ---
SYNC_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

while true; do
  sleep "$SYNC_INTERVAL"
  ((SYNC_COUNT++))
  echo "" # Add blank line for readability
  log "--- Sync #${SYNC_COUNT} ---"
  
  if sync_logs; then
    CONSECUTIVE_FAILURES=0
  else
    ((CONSECUTIVE_FAILURES++))
    log_warning "Consecutive failures: ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES}"
    
    if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      log_error "Too many consecutive failures (${CONSECUTIVE_FAILURES}). Exiting."
      exit 1
    fi
    
    log_warning "Will retry in ${SYNC_INTERVAL}s..."
  fi
done
