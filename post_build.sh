#!/bin/bash

VERBOSE=${VERBOSE:-0}
USERFILE="${USERFILE:-./user.dat}"
SSH_PUB_KEY="/ssh_key_busydocker.pub"

log() { [[ "$VERBOSE" == "1" ]] && echo "[INFO] $1"; }
err() { echo "[ERROR] $1" >&2; }

create_user() {
    local username="$1"
    local password="$2"
    
    log "Setting up user: $username"
    
    if [[ "$username" == "root" ]]; then
        if ! echo "$username:$password" | chpasswd -c SHA512 2>&1; then
            err "chpasswd failed for '$username'"
            return 1
        fi
        
        local home="/root"
        mkdir -p "$home/.ssh"
        chmod 700 "$home/.ssh"
        
        if [[ -f "$SSH_PUB_KEY" ]]; then
            cat "$SSH_PUB_KEY" >> "$home/.ssh/authorized_keys"
            chmod 600 "$home/.ssh/authorized_keys"
        fi
        return 0
    fi
    
    if id "$username" &>/dev/null; then
        log "User '$username' already exists, updating password"
        usermod -aG sudo "$username" 2>/dev/null || true
    else
        if ! useradd -rm -d "/home/$username" -s /bin/bash -g root -G sudo "$username" 2>&1; then
            err "useradd failed for '$username'"
            return 1
        fi
    fi
    
    if ! echo "$username:$password" | chpasswd -c SHA512 2>&1; then
        err "chpasswd failed for '$username'"
        return 1
    fi
    
    local home="/home/$username"
    mkdir -p "$home/.ssh" "$home/.vscode" "$home/.vscode-server"
    chown "$username" "$home/.ssh" "$home/.vscode" "$home/.vscode-server"
    
    if [[ -f "$SSH_PUB_KEY" ]]; then
        cat "$SSH_PUB_KEY" >> "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
        chown "$username" "$home/.ssh/authorized_keys"
    fi
    
    echo "$username ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$username"
    chmod 440 "/etc/sudoers.d/$username"
    log "Added '$username' to sudoers with NOPASSWD"
}

setup_sshd() {
    log "Configuring SSH daemon"
    sed -i "s/#Port.*/Port 22/" /etc/ssh/sshd_config
    sed -i "s/#X11UseLocalhost.*/X11UseLocalhost no/" /etc/ssh/sshd_config
    sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
    sed -i "s/#PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    mkdir -p /var/run/sshd
}

if [[ ! -f "$USERFILE" ]]; then
    echo "Error: User file not found: $USERFILE" >&2
    exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*$ || "$line" =~ ^# ]] && continue
    username="${line%%:*}"
    password="${line#*:}"
    password="${password%%:*}"
    if [[ -z "$username" || -z "$password" ]]; then
        log "Warning: Invalid line '$line', skipping"
        continue
    fi
    create_user "$username" "$password" || true
done < "$USERFILE"

setup_sshd
log "Post-build complete"
exit 0
