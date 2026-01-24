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
# Args: $1 = directory path, $2 = patch output path, $3 = name for logging, $4 = lfs files list output, $5 = remote HEAD hash (optional)
create_patch_for_repo() {
  local repo_dir="$1"
  local patch_path="$2"
  local repo_name="$3"
  local lfs_list_path="$4"
  local remote_head="${5:-}"
  
  cd "$repo_dir"
  
  # Check if it's a git repo
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_warning "$repo_name is not a git repository, skipping"
    return 1
  fi
  
  # Determine what to compare against
  local base_commit="HEAD"
  local has_uncommitted=false
  
  # If remote HEAD is provided and exists locally, use it as base
  if [ -n "$remote_head" ] && git cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
    base_commit="$remote_head"
    log "  $repo_name: Comparing against remote HEAD ${remote_head:0:8}"
  fi
  
  # Check if there are any uncommitted changes in working directory
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    has_uncommitted=true
  fi
  
  # Check for untracked files
  if [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    has_uncommitted=true
  fi
  
  # Check if local HEAD is ahead of base commit
  local has_commits=false
  if [ "$base_commit" != "HEAD" ]; then
    if ! git diff --quiet "$base_commit" HEAD 2>/dev/null; then
      has_commits=true
    fi
  fi
  
  # No changes at all
  if [ "$has_uncommitted" = false ] && [ "$has_commits" = false ]; then
    log "  $repo_name: No changes (up to date with remote)"
    return 1
  fi
  
  # Save current staged state
  local stash_needed=false
  if ! git diff --cached --quiet 2>/dev/null; then
    stash_needed=true
    git stash push --staged -m "transfer_temp_stash" >/dev/null 2>&1 || true
  fi
  
  # Stage ALL uncommitted changes including new files and deletions
  git add -A
  
  # Create patch: base_commit -> HEAD (committed) + working directory (uncommitted)
  # This will include both committed changes and uncommitted changes
  git diff --binary "$base_commit" HEAD > "$patch_path"
  
  # If there are uncommitted changes, append them to the patch
  if [ "$has_uncommitted" = true ]; then
    git diff --cached --binary HEAD >> "$patch_path"
  fi
  
  # Collect LFS tracked files that are new or modified
  if command -v git-lfs >/dev/null 2>&1; then
    # From base to HEAD
    git diff --name-only --diff-filter=AM "$base_commit" HEAD 2>/dev/null | while read -r file; do
      if [ -f "$file" ] && git check-attr filter "$file" 2>/dev/null | grep -q "filter: lfs"; then
        echo "$file" >> "$lfs_list_path"
      fi
    done
    # Uncommitted changes
    if [ "$has_uncommitted" = true ]; then
      git diff --cached --name-only --diff-filter=AM HEAD 2>/dev/null | while read -r file; do
        if [ -f "$file" ] && git check-attr filter "$file" 2>/dev/null | grep -q "filter: lfs"; then
          echo "$file" >> "$lfs_list_path"
        fi
      done
    fi
  fi
  
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
  
  if [ "$has_commits" = true ] && [ "$has_uncommitted" = true ]; then
    log "  $repo_name: Patch created (${patch_size}) - commits + uncommitted changes"
  elif [ "$has_commits" = true ]; then
    log "  $repo_name: Patch created (${patch_size}) - committed changes"
  else
    log "  $repo_name: Patch created (${patch_size}) - uncommitted changes"
  fi
  
  # Show summary
  git diff --stat "$base_commit" HEAD 2>/dev/null | head -15 | sed 's/^/      /'
  if [ "$has_uncommitted" = true ]; then
    git add -A
    git diff --cached --stat HEAD 2>/dev/null | head -5 | sed 's/^/      [WIP] /'
    git reset HEAD >/dev/null 2>&1 || true
  fi
  
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

# --- 0. Get remote HEAD commits ---
log "0. Querying remote repository state..."

# Get remote main repo HEAD
REMOTE_MAIN_HEAD=""
REMOTE_MAIN_HEAD=$(ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
  "cd '${REMOTE_PROJECT_DIR%/}' 2>/dev/null && git rev-parse HEAD 2>/dev/null" || echo "")

if [ -n "$REMOTE_MAIN_HEAD" ]; then
  log "  Remote main HEAD: ${REMOTE_MAIN_HEAD:0:8}"
else
  log_warning "  Could not get remote main HEAD (might be first sync)"
fi

# Get remote submodule HEADs
declare -A REMOTE_SUBMODULE_HEADS
cd "$LOCAL_PROJECT_DIR"
SUBMODULES=$(git submodule --quiet foreach 'echo $name:$sm_path' 2>/dev/null || true)

for submod in $SUBMODULES; do
  submod_name="${submod%%:*}"
  submod_path="${submod#*:}"
  
  remote_submod_head=$(ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
    "cd '${REMOTE_PROJECT_DIR%/}/${submod_path}' 2>/dev/null && git rev-parse HEAD 2>/dev/null" || echo "")
  
  if [ -n "$remote_submod_head" ]; then
    REMOTE_SUBMODULE_HEADS["$submod_name"]="$remote_submod_head"
    log "  Remote $submod_name HEAD: ${remote_submod_head:0:8}"
  else
    log_warning "  Could not get remote $submod_name HEAD"
  fi
done

log ""

# --- 1. Create bundles for commits and patches for uncommitted changes ---
log "1. Creating bundles and patches..."

BUNDLES_CREATED=()
PATCHES_CREATED=()
LFS_FILES_TO_TRANSFER=()

# Helper function to create bundle if commits differ
create_bundle_if_needed() {
  local repo_dir="$1"
  local bundle_path="$2"
  local repo_name="$3"
  local remote_head="$4"
  local relative_path="$5"
  
  cd "$repo_dir"
  
  if [ -n "$remote_head" ] && git cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
    # Check if local HEAD is different from remote HEAD
    local local_head=$(git rev-parse HEAD 2>/dev/null)
    if [ "$local_head" != "$remote_head" ]; then
      # Create bundle with commits from remote_head to local HEAD
      # Use explicit ref to ensure remote knows which commit is HEAD
      git bundle create "$bundle_path" "${remote_head}..HEAD" HEAD 2>/dev/null
      if [ -f "$bundle_path" ]; then
        log "  $repo_name: Bundle created (${remote_head:0:8}..${local_head:0:8})"
        echo "$local_head" > "${bundle_path}.head"  # Save target HEAD for remote
        return 0
      fi
    fi
  else
    # Remote HEAD not available or different, create full bundle
    local local_head=$(git rev-parse HEAD 2>/dev/null)
    git bundle create "$bundle_path" HEAD 2>/dev/null
    if [ -f "$bundle_path" ]; then
      log "  $repo_name: Full bundle created (${local_head:0:8})"
      echo "$local_head" > "${bundle_path}.head"  # Save target HEAD for remote
      return 0
    fi
  fi
  
  return 1
}

# Helper function to create patch for uncommitted changes only
create_uncommitted_patch() {
  local repo_dir="$1"
  local patch_path="$2"
  local repo_name="$3"
  local lfs_list_path="$4"
  
  cd "$repo_dir"
  
  # Check if there are uncommitted changes
  local has_uncommitted=false
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    has_uncommitted=true
  fi
  if [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    has_uncommitted=true
  fi
  
  if [ "$has_uncommitted" = false ]; then
    return 1
  fi
  
  # Save staged state
  local stash_needed=false
  if ! git diff --cached --quiet 2>/dev/null; then
    stash_needed=true
    git stash push --staged -m "transfer_temp" >/dev/null 2>&1 || true
  fi
  
  # Stage all changes
  git add -A
  
  # Collect LFS files
  if command -v git-lfs >/dev/null 2>&1; then
    git diff --cached --name-only --diff-filter=AM HEAD 2>/dev/null | while read -r file; do
      if [ -f "$file" ] && git check-attr filter "$file" 2>/dev/null | grep -q "filter: lfs"; then
        echo "$file" >> "$lfs_list_path"
      fi
    done
  fi
  
  # Create patch for uncommitted changes
  git diff --cached --binary HEAD > "$patch_path"
  
  # Restore
  git reset HEAD >/dev/null 2>&1 || true
  if [ "$stash_needed" = true ]; then
    git stash pop >/dev/null 2>&1 || true
  fi
  
  if [ -s "$patch_path" ]; then
    local patch_size=$(du -h "$patch_path" | cut -f1)
    log "  $repo_name: Uncommitted patch created (${patch_size})"
    return 0
  fi
  
  return 1
}

# Main repository
MAIN_BUNDLE="${PATCH_DIR}/main.bundle"
MAIN_PATCH="${PATCH_DIR}/main.patch"
MAIN_LFS_LIST="${PATCH_DIR}/main_lfs.txt"

if create_bundle_if_needed "$LOCAL_PROJECT_DIR" "$MAIN_BUNDLE" "main repo" "$REMOTE_MAIN_HEAD" "."; then
  BUNDLES_CREATED+=("main:$MAIN_BUNDLE:.")
fi

if create_uncommitted_patch "$LOCAL_PROJECT_DIR" "$MAIN_PATCH" "main repo" "$MAIN_LFS_LIST"; then
  PATCHES_CREATED+=("main:$MAIN_PATCH:.")
  if [ -f "$MAIN_LFS_LIST" ]; then
    while IFS= read -r lfs_file; do
      [ -n "$lfs_file" ] && LFS_FILES_TO_TRANSFER+=("./${lfs_file}:${LOCAL_PROJECT_DIR}")
    done < "$MAIN_LFS_LIST"
  fi
fi

# Submodules
cd "$LOCAL_PROJECT_DIR"
SUBMODULES=$(git submodule --quiet foreach 'echo $name:$sm_path' 2>/dev/null || true)

for submod in $SUBMODULES; do
  submod_name="${submod%%:*}"
  submod_path="${submod#*:}"
  submod_full_path="${LOCAL_PROJECT_DIR%/}/${submod_path}"
  submod_bundle="${PATCH_DIR}/${submod_name}.bundle"
  submod_patch="${PATCH_DIR}/${submod_name}.patch"
  submod_lfs_list="${PATCH_DIR}/${submod_name}_lfs.txt"
  remote_submod_head="${REMOTE_SUBMODULE_HEADS[$submod_name]:-}"
  
  if [ -d "$submod_full_path" ]; then
    if create_bundle_if_needed "$submod_full_path" "$submod_bundle" "$submod_name" "$remote_submod_head" "$submod_path"; then
      BUNDLES_CREATED+=("${submod_name}:${submod_bundle}:${submod_path}")
    fi
    
    if create_uncommitted_patch "$submod_full_path" "$submod_patch" "$submod_name" "$submod_lfs_list"; then
      PATCHES_CREATED+=("${submod_name}:${submod_patch}:${submod_path}")
      if [ -f "$submod_lfs_list" ]; then
        while IFS= read -r lfs_file; do
          [ -n "$lfs_file" ] && LFS_FILES_TO_TRANSFER+=("${submod_path}/${lfs_file}:${submod_full_path}")
        done < "$submod_lfs_list"
      fi
    fi
  fi
done

# Check if any changes were detected
if [ ${#BUNDLES_CREATED[@]} -eq 0 ] && [ ${#PATCHES_CREATED[@]} -eq 0 ]; then
  log_warning "No changes detected in any repository"
  rm -rf "$PATCH_DIR"
  exit 0
fi

log_success "Created ${#BUNDLES_CREATED[@]} bundle(s) and ${#PATCHES_CREATED[@]} patch(es)"

# --- 2. Upload bundles and patches to remote server ---
log ""
log "2. Uploading to remote server..."

REMOTE_PATCH_DIR="/tmp/patches_${TIMESTAMP}"
ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" "mkdir -p '$REMOTE_PATCH_DIR'"

# Upload bundles
for bundle_info in "${BUNDLES_CREATED[@]}"; do
  bundle_name="${bundle_info%%:*}"
  rest="${bundle_info#*:}"
  bundle_path="${rest%%:*}"
  
  scp -i "$SSH_KEY_PATH" "$bundle_path" "${TARGET_SERVER}:${REMOTE_PATCH_DIR}/" >/dev/null
  log "  Uploaded: ${bundle_name}.bundle"
  
  # Also upload the .head file if it exists
  if [ -f "${bundle_path}.head" ]; then
    scp -i "$SSH_KEY_PATH" "${bundle_path}.head" "${TARGET_SERVER}:${REMOTE_PATCH_DIR}/" >/dev/null
  fi
done

# Upload patches
for patch_info in "${PATCHES_CREATED[@]}"; do
  patch_name="${patch_info%%:*}"
  rest="${patch_info#*:}"
  patch_path="${rest%%:*}"
  
  scp -i "$SSH_KEY_PATH" "$patch_path" "${TARGET_SERVER}:${REMOTE_PATCH_DIR}/" >/dev/null
  log "  Uploaded: ${patch_name}.patch"
done

log_success "All files uploaded"

# --- 3. Apply bundles and patches on remote server ---
log ""
log "3. Applying changes on remote server..."

# Build the info for remote script
BUNDLES_INFO=""
for bundle_info in "${BUNDLES_CREATED[@]}"; do
  bundle_name="${bundle_info%%:*}"
  rest="${bundle_info#*:}"
  bundle_path="${rest%%:*}"
  relative_path="${rest#*:}"
  bundle_filename="$(basename "$bundle_path")"
  BUNDLES_INFO="${BUNDLES_INFO}${bundle_name}:${bundle_filename}:${relative_path}\n"
done

PATCHES_INFO=""
for patch_info in "${PATCHES_CREATED[@]}"; do
  patch_name="${patch_info%%:*}"
  rest="${patch_info#*:}"
  patch_path="${rest%%:*}"
  relative_path="${rest#*:}"
  patch_filename="$(basename "$patch_path")"
  PATCHES_INFO="${PATCHES_INFO}${patch_name}:${patch_filename}:${relative_path}\n"
done

ssh -i "$SSH_KEY_PATH" "$TARGET_SERVER" \
  "REMOTE_PROJECT_DIR='${REMOTE_PROJECT_DIR}' \
   REMOTE_PATCH_DIR='${REMOTE_PATCH_DIR}' \
   BUNDLES_INFO='${BUNDLES_INFO}' \
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

# Step 1: Apply bundles (commits)
if [ -n "$BUNDLES_INFO" ]; then
  log "Applying bundles (commits)..."
  
  # Disable LFS to avoid credential issues during reset/checkout
  export GIT_LFS_SKIP_SMUDGE=1
  
  echo -e "$BUNDLES_INFO" | while IFS=: read -r bundle_name bundle_file relative_path; do
    [ -z "$bundle_name" ] && continue
    
    bundle_full_path="${REMOTE_PATCH_DIR}/${bundle_file}"
    target_dir="${REMOTE_PROJECT_DIR%/}/${relative_path}"
    
    cd "$target_dir" || { log_error "Cannot cd to: $target_dir"; continue; }
    
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      log_error "$bundle_name: Not a git repository"
      continue
    fi
    
    # Clean workspace first
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      log_warning "$bundle_name: Cleaning workspace before bundle apply..."
      git reset --hard HEAD >/dev/null 2>&1
      git clean -fd >/dev/null 2>&1
    fi
    
    # Verify bundle
    if ! git bundle verify "$bundle_full_path" >/dev/null 2>&1; then
      log_error "$bundle_name: Invalid bundle"
      continue
    fi
    
    # Fetch from bundle
    git fetch "$bundle_full_path" 2>&1 | head -3
    
    # Get target HEAD from .head file
    target_head=""
    if [ -f "${bundle_full_path}.head" ]; then
      target_head=$(cat "${bundle_full_path}.head")
      log "  Target commit: ${target_head:0:8}"
    fi
    
    # Reset to the target HEAD (with LFS disabled)
    if [ -n "$target_head" ] && git cat-file -e "$target_head" 2>/dev/null; then
      log "  Resetting to ${target_head:0:8}..."
      git reset --hard "$target_head" 2>&1 | head -3
      new_head=$(git rev-parse HEAD 2>/dev/null)
      if [ "$new_head" = "$target_head" ]; then
        log_success "$bundle_name: Reset to ${new_head:0:8}"
      else
        log_error "$bundle_name: Reset failed (expected ${target_head:0:8}, got ${new_head:0:8})"
      fi
    else
      log_error "$bundle_name: Target commit $target_head not found after fetch"
    fi
    
    rm -f "$bundle_full_path"
    rm -f "${bundle_full_path}.head"
  done
  
  unset GIT_LFS_SKIP_SMUDGE
fi

# Step 2: Apply patches (uncommitted changes)
if [ -n "$PATCHES_INFO" ]; then
  log "Applying patches (uncommitted changes)..."
  export GIT_LFS_SKIP_SMUDGE=1
  
  echo -e "$PATCHES_INFO" | while IFS=: read -r patch_name patch_file relative_path; do
    [ -z "$patch_name" ] && continue
    
    patch_full_path="${REMOTE_PATCH_DIR}/${patch_file}"
    target_dir="${REMOTE_PROJECT_DIR%/}/${relative_path}"
    
    cd "$target_dir" || { log_error "Cannot cd to: $target_dir"; continue; }
    
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      log_error "$patch_name: Not a git repository"
      continue
    fi
    
    # Clean any uncommitted changes first (to ensure clean apply)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      log_warning "$patch_name: Cleaning uncommitted changes before apply..."
      git reset --hard HEAD >/dev/null 2>&1
      git clean -fd >/dev/null 2>&1
    fi
    
    # Apply patch
    if git apply --check "$patch_full_path" 2>/dev/null; then
      git apply --binary "$patch_full_path" 2>&1 | head -10
      log_success "$patch_name: Uncommitted changes applied"
      git status --short 2>/dev/null | head -10 | sed 's/^/      /'
    else
      log_error "$patch_name: Patch failed to apply"
      git apply --check "$patch_full_path" 2>&1 | head -5 | sed 's/^/      /'
    fi
    
    rm -f "$patch_full_path"
  done
  
  unset GIT_LFS_SKIP_SMUDGE
fi

# Cleanup
rm -rf "$REMOTE_PATCH_DIR"
log_success "Cleanup completed"
EOF

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
