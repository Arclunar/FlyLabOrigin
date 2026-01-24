#!/usr/bin/env bash
#
# Syncs local changes (including submodules) to remote server using git diff.
# Handles new files, deleted files, and modifications in both main repo and submodules.
#
# ======================================================================================
# CONFIGURATION
# ======================================================================================

# Remote Server Configuration
SERVER_IP="${SERVER_IP:-14.103.52.172}"
REMOTE_USER="${REMOTE_USER:-zhw}"

# Local Project Directory
LOCAL_PROJECT_DIR="${LOCAL_PROJECT_DIR:-$HOME/framework/server/}"

# Remote Project Directory (注意：远端用户是 zhw，不是本地用户)
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/home/zhw/framework/server/}"

# SSH Key Configuration
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"

# Local temporary directory
LOCAL_TMP_DIR="${LOCAL_TMP_DIR:-${TMPDIR:-/tmp/}}"

# Construct target server
TARGET_SERVER="${REMOTE_USER}@${SERVER_IP}"

# ======================================================================================

set -euo pipefail

# ======================================================================================
# ANSI Color Codes
# ======================================================================================
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# ======================================================================================
# Logging Functions
# ======================================================================================

log() {
  printf "${COLOR_BLUE}[%s]${COLOR_RESET} %s\n" "$(date '+%H:%M:%S')" "$*"
}

log_success() {
  printf "${COLOR_GREEN}[%s] ✓ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

log_error() {
  printf "${COLOR_RED}[%s] ✗ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_warning() {
  printf "${COLOR_YELLOW}[%s] ⚠ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"
}

# ======================================================================================
# Helper Functions
# ======================================================================================

# Create a git diff patch for a directory (handles new/deleted files)
# Args: $1 = directory path, $2 = patch output path, $3 = name for logging, $4 = lfs files list output
create_patch_for_repo() {
  local repo_dir="$1"
  local patch_path="$2"
  local repo_name="$3"
  local lfs_list_path="$4"
  
  cd "$repo_dir"
  
  # Check if it's a git repo
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_warning "$repo_name is not a git repository, skipping"
    return 1
  fi
  
  # Check if there are any changes (tracked or untracked)
  local has_changes=false
  
  # Check for modified/deleted tracked files
  if ! git diff --quiet HEAD 2>/dev/null; then
    has_changes=true
  fi
  
  # Check for staged changes
  if ! git diff --cached --quiet 2>/dev/null; then
    has_changes=true
  fi
  
  # Check for untracked files
  if [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    has_changes=true
  fi
  
  if [ "$has_changes" = false ]; then
    log "  $repo_name: No changes"
    return 1
  fi
  
  # Save current staged state
  local stash_needed=false
  if ! git diff --cached --quiet 2>/dev/null; then
    stash_needed=true
    git stash push --staged -m "transfer_temp_stash" >/dev/null 2>&1 || true
  fi
  
  # Stage ALL changes including new files and deletions
  git add -A
  
  # Collect LFS tracked files that are new or modified
  if command -v git-lfs >/dev/null 2>&1; then
    git diff --cached --name-only --diff-filter=AM HEAD 2>/dev/null | while read -r file; do
      if [ -f "$file" ] && git check-attr filter "$file" 2>/dev/null | grep -q "filter: lfs"; then
        echo "$file" >> "$lfs_list_path"
      fi
    done
  fi
  
  # Create the patch with --cached --binary to include everything
  git diff --cached --binary HEAD > "$patch_path"
  
  # Restore staging area
  git reset HEAD >/dev/null 2>&1 || true
  
  # Restore previously staged changes
  if [ "$stash_needed" = true ]; then
    git stash pop >/dev/null 2>&1 || true
  fi
  
  # Check if patch has content
  if [ ! -s "$patch_path" ]; then
    return 1
  fi
  
  local patch_size
  patch_size="$(du -h "$patch_path" | cut -f1)"
  log "  $repo_name: Patch created (${patch_size})"
  
  # Show summary
  git add -A
  git diff --cached --stat HEAD 2>/dev/null | head -20 | sed 's/^/      /'
  git reset HEAD >/dev/null 2>&1 || true
  
  return 0
}

# ======================================================================================
# Main Script
# ======================================================================================

# Check if local directory exists
if [ ! -d "$LOCAL_PROJECT_DIR" ]; then
  log_error "Local directory not found: $LOCAL_PROJECT_DIR"
  exit 1
fi

# Check prerequisites
for cmd in git ssh scp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Command '$cmd' is required but not found in PATH."
    exit 1
  fi
done

cd "$LOCAL_PROJECT_DIR"

# Verify it's a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  log_error "Not a git repository: $LOCAL_PROJECT_DIR"
  exit 1
fi

# ======================================================================================
# Generate Patches
# ======================================================================================

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
LOCAL_TMP_DIR="${LOCAL_TMP_DIR%/}/"
PATCH_DIR="${LOCAL_TMP_DIR}patches_${TIMESTAMP}"
mkdir -p "$PATCH_DIR"

log ""
log "=========================================="
log "Transfer Codebase by Git Diff"
log "=========================================="
log ""
log "Configuration:"
log "  Local Path:      ${LOCAL_PROJECT_DIR}"
log "  Remote Path:     ${REMOTE_PROJECT_DIR}"
log "  Target Server:   ${TARGET_SERVER}"
log "  SSH Key:         ${SSH_KEY_PATH}"
log ""

# --- 1. Collect patches from main repo and submodules ---
log "1. Creating patches..."

PATCHES_CREATED=()
LFS_FILES_TO_TRANSFER=()

# Main repository
MAIN_PATCH="${PATCH_DIR}/main.patch"
MAIN_LFS_LIST="${PATCH_DIR}/main_lfs.txt"
if create_patch_for_repo "$LOCAL_PROJECT_DIR" "$MAIN_PATCH" "main repo" "$MAIN_LFS_LIST"; then
  PATCHES_CREATED+=("main:$MAIN_PATCH:.")
  if [ -f "$MAIN_LFS_LIST" ]; then
    while IFS= read -r lfs_file; do
      [ -n "$lfs_file" ] && LFS_FILES_TO_TRANSFER+=("./${lfs_file}:${LOCAL_PROJECT_DIR}")
    done < "$MAIN_LFS_LIST"
  fi
fi

# Get list of submodules
cd "$LOCAL_PROJECT_DIR"
SUBMODULES=$(git submodule --quiet foreach 'echo $name:$sm_path' 2>/dev/null || true)

for submod in $SUBMODULES; do
  submod_name="${submod%%:*}"
  submod_path="${submod#*:}"
  submod_full_path="${LOCAL_PROJECT_DIR%/}/${submod_path}"
  submod_patch="${PATCH_DIR}/${submod_name}.patch"
  submod_lfs_list="${PATCH_DIR}/${submod_name}_lfs.txt"
  
  if [ -d "$submod_full_path" ]; then
    if create_patch_for_repo "$submod_full_path" "$submod_patch" "$submod_name" "$submod_lfs_list"; then
      PATCHES_CREATED+=("${submod_name}:${submod_patch}:${submod_path}")
      if [ -f "$submod_lfs_list" ]; then
        while IFS= read -r lfs_file; do
          [ -n "$lfs_file" ] && LFS_FILES_TO_TRANSFER+=("${submod_path}/${lfs_file}:${submod_full_path}")
        done < "$submod_lfs_list"
      fi
    fi
  fi
done

# Check if any patches were created
if [ ${#PATCHES_CREATED[@]} -eq 0 ]; then
  log_warning "No changes detected in any repository"
  rm -rf "$PATCH_DIR"
  exit 0
fi

log_success "Created ${#PATCHES_CREATED[@]} patch(es)"

# --- 2. Upload patches to remote server ---
log ""
log "2. Uploading patches to remote server..."

REMOTE_PATCH_DIR="/tmp/patches_${TIMESTAMP}"
ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" "mkdir -p '$REMOTE_PATCH_DIR'"

for patch_info in "${PATCHES_CREATED[@]}"; do
  patch_name="${patch_info%%:*}"
  rest="${patch_info#*:}"
  patch_path="${rest%%:*}"
  
  scp -i "$SSH_KEY_PATH" "$patch_path" "${TARGET_SERVER}:${REMOTE_PATCH_DIR}/" >/dev/null
  log "  Uploaded: ${patch_name}.patch"
done

log_success "All patches uploaded"

# --- 3. Apply patches on remote server ---
log ""
log "3. Applying patches on remote server..."

# Build the patches info for remote script
PATCHES_INFO=""
for patch_info in "${PATCHES_CREATED[@]}"; do
  patch_name="${patch_info%%:*}"
  rest="${patch_info#*:}"
  patch_path="${rest%%:*}"
  relative_path="${rest#*:}"
  patch_filename="$(basename "$patch_path")"
  PATCHES_INFO="${PATCHES_INFO}${patch_name}:${patch_filename}:${relative_path}\n"
done

REMOTE_OUTPUT=$(ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
  "REMOTE_PROJECT_DIR='${REMOTE_PROJECT_DIR}' \
   REMOTE_PATCH_DIR='${REMOTE_PATCH_DIR}' \
   PATCHES_INFO='${PATCHES_INFO}' \
   COLOR_GREEN='\033[0;32m' \
   COLOR_RED='\033[0;31m' \
   COLOR_YELLOW='\033[0;33m' \
   COLOR_BLUE='\033[0;34m' \
   COLOR_RESET='\033[0m' \
   bash -s" <<'EOF'
set -uo pipefail

log() { printf "${COLOR_BLUE}[%s]${COLOR_RESET} %s\n" "$(date '+%H:%M:%S')" "$*"; }
log_success() { printf "${COLOR_GREEN}[%s] ✓ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"; }
log_error() { printf "${COLOR_RED}[%s] ✗ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"; }
log_warning() { printf "${COLOR_YELLOW}[%s] ⚠ %s${COLOR_RESET}\n" "$(date '+%H:%M:%S')" "$*"; }

cd "${REMOTE_PROJECT_DIR%/}" || { log_error "Failed to cd to: ${REMOTE_PROJECT_DIR}"; exit 1; }

# Process each patch
echo -e "$PATCHES_INFO" | while IFS=: read -r patch_name patch_file relative_path; do
  [ -z "$patch_name" ] && continue
  
  patch_full_path="${REMOTE_PATCH_DIR}/${patch_file}"
  target_dir="${REMOTE_PROJECT_DIR%/}/${relative_path}"
  
  if [ ! -f "$patch_full_path" ]; then
    log_error "Patch file not found: $patch_full_path"
    continue
  fi
  
  cd "$target_dir" || { log_error "Cannot cd to: $target_dir"; continue; }
  
  # Check if git repo
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "$patch_name: Not a git repository"
    continue
  fi
  
  # Reset any uncommitted changes on remote (remote should match git state)
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log_warning "$patch_name: Resetting uncommitted changes..."
    git reset --hard HEAD >/dev/null 2>&1
  fi
  
  # Clean untracked files
  git clean -fd >/dev/null 2>&1 || true
  
  # Temporarily disable Git LFS to avoid credential issues during patch apply
  export GIT_LFS_SKIP_SMUDGE=1
  
  # Apply patch (with LFS disabled to avoid download issues)
  if git apply --check "$patch_full_path" 2>/dev/null; then
    git apply --binary "$patch_full_path" 2>&1 | head -20
    log_success "$patch_name: Patch applied successfully"
    git status --short 2>/dev/null | head -20 | sed 's/^/      /'
  else
    log_error "$patch_name: Patch failed to apply cleanly"
    git apply --check "$patch_full_path" 2>&1 | head -10 | sed 's/^/      /'
  fi
  
  # Re-enable LFS
  unset GIT_LFS_SKIP_SMUDGE
  
  rm -f "$patch_full_path"
done

# Cleanup
rm -rf "$REMOTE_PATCH_DIR"
log_success "Cleanup completed"
EOF
) || true

echo "$REMOTE_OUTPUT"

# --- 4. Transfer LFS files ---
if [ ${#LFS_FILES_TO_TRANSFER[@]} -gt 0 ]; then
  log ""
  log "4. Transferring LFS files (${#LFS_FILES_TO_TRANSFER[@]} files)..."
  
  for lfs_info in "${LFS_FILES_TO_TRANSFER[@]}"; do
    relative_path="${lfs_info%%:*}"
    source_dir="${lfs_info#*:}"
    local_file="${source_dir}/${relative_path#*/}"
    remote_file="${REMOTE_PROJECT_DIR%/}/${relative_path}"
    
    if [ -f "$local_file" ]; then
      # Check if it's actually a real file (not just LFS pointer)
      if ! grep -q "version https://git-lfs.github.com" "$local_file" 2>/dev/null; then
        log "  Transferring: ${relative_path}"
        # Create remote directory if needed
        remote_dir=$(dirname "$remote_file")
        ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" "mkdir -p '$remote_dir'"
        # Transfer the actual file
        scp -i "$SSH_KEY_PATH" "$local_file" "${TARGET_SERVER}:${remote_file}" >/dev/null 2>&1
      else
        log_warning "  Skipping LFS pointer (not downloaded locally): ${relative_path}"
      fi
    fi
  done
  
  log_success "LFS files transferred"
fi

# --- 5. Cleanup local patches ---
log ""
log "5. Cleaning up local patches..."
rm -rf "$PATCH_DIR"
log_success "Local cleanup completed"

# --- Done ---
log ""
log_success "=========================================="
log_success "Deployment completed!"
log_success "=========================================="
log ""
log "Changes have been applied to ${TARGET_SERVER}:${REMOTE_PROJECT_DIR}"
log ""
log "To verify on remote:"
log "  ssh ${TARGET_SERVER}"
log "  cd ${REMOTE_PROJECT_DIR}"
log "  git status"
log "  git submodule foreach 'git status'"
