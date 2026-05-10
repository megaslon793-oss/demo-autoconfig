#!/bin/bash
# apply_router_ssh_22_bruteforce_0_6_18.sh
# Run from project root.
# Aggressively fixes every Router SSH port default/prompt to 22.

set +e

VERSION_VALUE="0.6.18-router-ssh-22-bruteforce"

if [ ! -d "modules" ] && [ ! -f "menu.sh" ]; then
  echo "[FAIL] Run this script from project root"
  exit 1
fi

BACKUP_DIR=".patch_backups/0.6.18-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
}

patch_file() {
  local f="$1"
  [ -f "$f" ] || return 0

  backup_file "$f"

  # 1. Visible prompt exactly.
  perl -0pi -e 's/Router SSH port \[\s*2026\s*\]/Router SSH port [22]/g' "$f"

  # 2. Any line containing Router SSH port and 2026.
  # Examples:
  # prompt "Router SSH port" "2026"
  # ask "Router SSH port [2026]:"
  # read_value "Router SSH port" SSH_ROUTER_PORT "2026"
  perl -0pi -e 's/(Router SSH port[^\n\r]*?)2026/${1}22/g' "$f"

  # 3. Any direct shell defaults for SSH_ROUTER_PORT.
  perl -0pi -e 's/SSH_ROUTER_PORT="\$\{SSH_ROUTER_PORT:-2026\}"/SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"/g' "$f"
  perl -0pi -e 's/SSH_ROUTER_PORT=\$\{SSH_ROUTER_PORT:-2026\}/SSH_ROUTER_PORT=${SSH_ROUTER_PORT:-22}/g' "$f"
  perl -0pi -e "s/SSH_ROUTER_PORT='\\\$\\{SSH_ROUTER_PORT:-2026\\}'/SSH_ROUTER_PORT='\\\${SSH_ROUTER_PORT:-22}'/g" "$f"
  perl -0pi -e 's/(^|\n)([[:space:]]*SSH_ROUTER_PORT=)2026(\n|$)/${1}${2}22${3}/g' "$f"

  # 4. config/env variants.
  perl -0pi -e 's/(^|\n)([[:space:]]*export[[:space:]]+SSH_ROUTER_PORT=)2026(\n|$)/${1}${2}22${3}/g' "$f"
  perl -0pi -e 's/(^|\n)([[:space:]]*SSH_ROUTER_PORT=["'\'']?)2026(["'\'']?[[:space:]]*(?:#.*?)?\n)/${1}${2}22${3}/g' "$f"

  # 5. Ansible router inventory lines.
  perl -0pi -e 's/(hq-rtr[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
  perl -0pi -e 's/(br-rtr[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
  perl -0pi -e 's/(ansible_user=(?:net_admin|\$\{SSH_ROUTER_USER\}|"\$SSH_ROUTER_USER")[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
  perl -0pi -e 's/(ansible_port=)2026([^\n\r]*ansible_user=(?:net_admin|\$\{SSH_ROUTER_USER\}|"\$SSH_ROUTER_USER"))/${1}22${2}/g' "$f"
}

# Patch all text-like project files, including README too, so grep does not scare you.
find . -type f \
  \( -name "*.sh" -o -name "*.env" -o -name "*.example" -o -name "*.md" -o -name "*.txt" -o -name "*.cfg" -o -name "hosts" -o -name "VERSION" \) \
  -not -path "./.git/*" \
  -not -path "./.patch_backups/*" | while read -r f; do
    patch_file "${f#./}"
done

# Hard append/overwrite correct values in config example.
if [ -f config/config.env.example ]; then
  backup_file config/config.env.example
  grep -q '^SSH_SERVER_PORT=' config/config.env.example && sed -i 's/^SSH_SERVER_PORT=.*/SSH_SERVER_PORT=2026/' config/config.env.example || echo 'SSH_SERVER_PORT=2026' >> config/config.env.example
  grep -q '^SSH_ROUTER_PORT=' config/config.env.example && sed -i 's/^SSH_ROUTER_PORT=.*/SSH_ROUTER_PORT=22/' config/config.env.example || echo 'SSH_ROUTER_PORT=22' >> config/config.env.example
  grep -q '^SSH_CLI_PORT=' config/config.env.example && sed -i 's/^SSH_CLI_PORT=.*/SSH_CLI_PORT=22/' config/config.env.example || echo 'SSH_CLI_PORT=22' >> config/config.env.example
  grep -q '^HQ_CLI_ANSIBLE_PORT=' config/config.env.example && sed -i 's/^HQ_CLI_ANSIBLE_PORT=.*/HQ_CLI_ANSIBLE_PORT=22/' config/config.env.example || echo 'HQ_CLI_ANSIBLE_PORT=22' >> config/config.env.example
fi

# Add runtime guard that will force correct values even if old config.env exists on VM.
mkdir -p modules
cat > modules/router_ssh_22_runtime_guard.sh <<'EOF'
#!/bin/bash
# Runtime guard: servers=2026, routers=22, client=22.

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

mkdir -p /etc/demo-autoconfig "$(dirname "$LOG_FILE")" 2>/dev/null || true
[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

set_kv() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
}

set_kv SSH_SERVER_PORT 2026
set_kv SSH_ROUTER_PORT 22
set_kv SSH_CLI_PORT 22
set_kv HQ_CLI_ANSIBLE_PORT 22

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"
case "$ROLE" in
  HQ-RTR|hq-rtr|BR-RTR|br-rtr|hqr|brr)
    if [ -f /etc/ssh/sshd_config ]; then
      if grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
        sed -i 's/^[#[:space:]]*Port[[:space:]].*/Port 22/' /etc/ssh/sshd_config
      else
        echo 'Port 22' >> /etc/ssh/sshd_config
      fi
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi
    ;;
esac

echo "$(date '+%F %T') [OK] Router SSH runtime guard: server=2026 router=22 client=22" | tee -a "$LOG_FILE"
EOF
chmod +x modules/router_ssh_22_runtime_guard.sh

# Force guard call at the top of entrypoints.
for f in modules/initial_setup.sh modules/module1.sh modules/module2.sh modules/module3.sh menu.sh; do
  if [ -f "$f" ]; then
    backup_file "$f"
    if ! grep -q 'router_ssh_22_runtime_guard.sh' "$f"; then
      tmp="$(mktemp)"
      {
        echo 'if [ -f /opt/demo-autoconfig/modules/router_ssh_22_runtime_guard.sh ]; then'
        echo '  bash /opt/demo-autoconfig/modules/router_ssh_22_runtime_guard.sh'
        echo 'elif [ -f "$(dirname "$0")/router_ssh_22_runtime_guard.sh" ]; then'
        echo '  bash "$(dirname "$0")/router_ssh_22_runtime_guard.sh"'
        echo 'fi'
        echo
        cat "$f"
      } > "$tmp"
      mv "$tmp" "$f"
      chmod +x "$f" 2>/dev/null || true
    fi
  fi
done

echo "$VERSION_VALUE" > VERSION

echo
echo "[OK] Applied brute-force router SSH port fix"
echo "[OK] Backups saved to $BACKUP_DIR"
echo
echo "Remaining suspicious lines:"
grep -R "Router SSH port.*2026\\|SSH_ROUTER_PORT.*2026" -n . \
  --exclude-dir=.git \
  --exclude-dir=.patch_backups \
  --exclude="*.zip" \
  --exclude="*.tar.gz" 2>/dev/null || true

echo
echo "Now run:"
echo "git add ."
echo "git commit -m \"force router ssh port to 22 everywhere\""
echo "git push"
