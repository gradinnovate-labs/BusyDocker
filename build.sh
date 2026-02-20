#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="busydocker:latest"
CONTAINER_NAME="busydocker_inst"
SSH_KEY_NAME="ssh_key_busydocker"
SSH_ALIAS="busydocker"
USER_FILE="user.dat"

VERBOSE=0
BUILD=0
RUN=0
PRUNE=0
SSH_PORT=22
WORKSPACE_PATH="${PWD}/workspace"
USER_NAME="${USER:-$(whoami 2>/dev/null || echo 'user')}"

log() { echo "[INFO] $1"; }
logv() { (( VERBOSE )) && echo "[DEBUG] $1" || true; }
error() { echo "[ERROR] $1" >&2; exit 1; }

CYAN='\033[36m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

prompt() { printf '\033[36m\033[1m%s\033[0m' "$1" >/dev/tty; }

check_yes_no() {
    local prompt_msg="$1"
    local key
    prompt "$prompt_msg" >/dev/tty
    read -rp " [y/N]: " key </dev/tty
    [[ "${key:0:1}" =~ [yY] ]]
}

prompt_input() {
    local prompt_msg="$1"
    local default_val="$2"
    local result
    prompt "$prompt_msg" >/dev/tty
    read -rp " [$default_val]: " result </dev/tty
    echo "${result:-$default_val}"
}

prompt_password() {
    local prompt_msg="$1"
    local result
    prompt "$prompt_msg" >/dev/tty
    read -rsp ": " result </dev/tty
    echo "$result"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Commands:
    --build     Build docker image
    --run       Run docker container
    --prune     Stop and remove container + image

    Options:
    --verbose   Enable verbose output
    --port N    SSH port (default: 22)
    --workspace PATH  Workspace path to mount (default: ./workspace)
    --user N    Username for volume mount (default: \$USER)
    -h, --help  Show this help

Examples:
    $0 --build --verbose
    $0 --run --port 2222
    $0 --run --workspace /path/to/project
    $0 --prune
EOF
    exit 0
}

check_deps() {
    command -v docker >/dev/null || error "docker is required but not installed"
    
    if ! docker info &>/dev/null; then
        cat >&2 << 'EOF'
[ERROR] Docker daemon is not running.

Please start Docker:
  - macOS: Open "Docker Desktop" from Applications
  - Linux: Run "sudo systemctl start docker"
  - Or run: open -a Docker  (macOS)
EOF
        exit 1
    fi
}

gen_ssh_key() {
    if check_yes_no "Generate SSH key for passwordless login?"; then
        logv "Generating SSH key: $SSH_KEY_NAME"
        ssh-keygen -f "$SSH_KEY_NAME" -N '' -q
        cp "$SSH_KEY_NAME"* ~/.ssh/ 2>/dev/null || true
    fi
}

del_ssh_key() {
    if [[ -f "${SSH_KEY_NAME}.pub" ]]; then
        rm -f "$SSH_KEY_NAME"*
    fi
}

setup_user_dat() {
    local default_user="${USER:-$(whoami 2>/dev/null || echo 'user')}"
    local login_user login_pass uid gid
    
    if check_yes_no "Configure container login user?"; then
        login_user=$(prompt_input "Login username" "$default_user")
        login_pass=""
        while [[ -z "$login_pass" ]]; do
            login_pass=$(prompt_password "Password for '$login_user'")
            if [[ -z "$login_pass" ]]; then
                echo -e "\n${YELLOW}Password cannot be empty${RESET}" >/dev/tty
            fi
        done
        echo >/dev/tty
        uid=$(id -u)
        gid=$(id -g)
    else
        login_user="root"
        login_pass="2026ncue"
        uid=""
        gid=""
        log "Using default: root / 2026ncue"
    fi
    
    USER_NAME="$login_user"
    echo "${login_user}:${login_pass}:${SSH_PORT}:${uid}:${gid}" > "$USER_FILE"
    logv "Generated $USER_FILE for user: $login_user, port: $SSH_PORT, uid: ${uid:-N/A}, gid: ${gid:-N/A}"
}

cleanup_user_dat() {
    if [[ -f "$USER_FILE" ]]; then
        rm -f "$USER_FILE"
        logv "Cleaned up $USER_FILE"
    fi
}

get_saved_username() {
    if [[ -f "$USER_FILE" ]]; then
        cut -d: -f1 "$USER_FILE"
    else
        echo "${USER:-$(whoami 2>/dev/null || echo 'user')}"
    fi
}

get_saved_port() {
    if [[ -f "$USER_FILE" ]]; then
        cut -d: -f3 "$USER_FILE"
    else
        echo "22"
    fi
}

setup_ssh_config() {
    local ssh_dir="$HOME/.ssh"
    local config_file="$ssh_dir/config"
    local key_file="$ssh_dir/${SSH_KEY_NAME}"
    
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    if [[ ! -f "$key_file" && -f "${SSH_KEY_NAME}" ]]; then
        cp "${SSH_KEY_NAME}"* "$ssh_dir/"
        logv "Copied SSH key to $ssh_dir"
    fi
    
    touch "$config_file"
    
    if grep -q "^Host ${SSH_ALIAS}$" "$config_file" 2>/dev/null; then
        if ! check_yes_no "Host '${SSH_ALIAS}' already in ~/.ssh/config. Overwrite?"; then
            log "Skipped SSH config update"
            return
        fi
        local tmp_file="${config_file}.tmp"
        awk -v alias="$SSH_ALIAS" '
            $0 == "Host " alias { skip=1; next }
            skip && /^[^[:space:]]/ { skip=0 }
            !skip { print }
        ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
        logv "Removed existing '${SSH_ALIAS}' entry"
    fi
    
    cat >> "$config_file" << EOF

Host ${SSH_ALIAS}
    HostName localhost
    Port ${SSH_PORT}
    User ${USER_NAME}
    IdentityFile ~/.ssh/${SSH_KEY_NAME}
EOF
    
    log "Added '${SSH_ALIAS}' to ~/.ssh/config"
    log "Connect with: ssh ${SSH_ALIAS}"
}

do_build() {
    setup_user_dat
    log "Building image: $IMAGE_NAME"
    gen_ssh_key
    
    local build_args=(docker build . -f Dockerfile.ssh -t "$IMAGE_NAME")
    (( VERBOSE )) && build_args+=(--progress=plain)
    "${build_args[@]}"
    
    del_ssh_key
    log "Build complete"
    
    if check_yes_no "Configure ~/.ssh/config for easy access?"; then
        setup_ssh_config
    fi
}

do_run() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "Container '$CONTAINER_NAME' already exists. Use --prune first."
    fi
    
    local run_user saved_port
    run_user=$(get_saved_username)
    saved_port=$(get_saved_port)
    
    if [[ "$SSH_PORT" != "$saved_port" ]]; then
        echo -e "${YELLOW}[WARNING] Port mismatch! Build port: $saved_port, Run port: $SSH_PORT${RESET}"
        echo "[WARNING] SSH config may not work correctly"
    fi
    
    mkdir -p "$WORKSPACE_PATH"
    
    log "Starting container: $CONTAINER_NAME (SSH port: $SSH_PORT)"
    log "Mounting workspace: $WORKSPACE_PATH → /workspace"
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "${SSH_PORT}:22" \
        -e DISPLAY="docker.for.mac.host.internal:0" \
        -v vscode-server:/home/"$run_user"/.vscode-server \
        -v "${WORKSPACE_PATH}:/workspace" \
        "$IMAGE_NAME"
    
    log "Container started. Connect: ssh -p $SSH_PORT ${run_user}@localhost"
}

do_prune() {
    log "Stopping and removing container..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    
    log "Removing image..."
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
    
    cleanup_user_dat
    
    log "Prune complete"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build ) BUILD=1; shift ;;
        --run ) RUN=1; shift ;;
        --prune ) PRUNE=1; shift ;;
        --verbose ) VERBOSE=1; shift ;;
        --port ) SSH_PORT="${2:-22}"; shift 2 ;;
        --workspace ) WORKSPACE_PATH="${2:-$PWD/workspace}"; shift 2 ;;
        --user ) USER_NAME="${2:-$USER}"; shift 2 ;;
        -h|--help ) usage ;;
        * ) error "Unknown option: $1" ;;
    esac
done

check_deps

cmd_count=$((BUILD + RUN + PRUNE))
(( cmd_count == 0 )) && usage
(( cmd_count > 1 )) && error "Only one command allowed at a time"

(( BUILD )) && do_build
(( RUN )) && do_run
(( PRUNE )) && do_prune
