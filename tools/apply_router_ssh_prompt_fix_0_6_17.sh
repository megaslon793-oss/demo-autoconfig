#!/bin/bash
# apply_router_ssh_prompt_fix_0_6_17.sh
# Run from project root.
# Purpose: force Router SSH port default/prompt/source/runtime to 22.

set +e

ROOT="$(pwd)"
VERSION_VALUE="0.6.17-router-ssh-prompt-22"

echo "[INFO] Project root: $ROOT"

if [ ! -d "modules" ] && [ ! -f "menu.sh" ]; then
  echo "[FAIL] Run this script from the demo-autoconfig project root"
  exit 1
fi

BACKUP_DIR=".patch_backups/0.6.17-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
}

patch_text_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  backup_file "$f"

  # Direct visible prompt fixes.
  perl -0pi -e 's/Router SSH port \[2026\]/Router SSH port [22]/g' "$f"
  perl -0pi -e 's/(Router SSH port[^\n\r]*\[\s*)2026(\s*\])/${1}22${2}/g' "$f"

  # Variable default fixes.
  perl -0pi -e 's/SSH_ROUTER_PORT="\$\{SSH_ROUTER_PORT:-2026\}"/SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"/g' "$f"
  perl -0pi -e "s/SSH_ROUTER_PORT='\\\$\\{SSH_ROUTER_PORT:-2026\\}'/SSH_ROUTER_PORT='\\\${SSH_ROUTER_PORT:-22}'/g" "$f"
  perl -0pi -e 's/SSH_ROUTER_PORT=\$\{SSH_ROUTER_PORT:-2026\}/SSH_ROUTER_PORT=${SSH_ROUTER_PORT:-22}/g' "$f"
  perl -0pi -e 's/SSH_ROUTER_PORT=22/SSH_ROUTER_PORT=22/g' "$f"

  # Prompt functions often look like:
  # prompt "Router SSH port" "22" ...
  # ask_value "Router SSH port" SSH_ROUTER_PORT "22"
  perl -0pi -e 's/(Router SSH port["'\''][,\)\s]+["'\''])2026(["'\''])/${1}22${2}/g' "$f"
  perl -0pi -e 's/(Router SSH port[^;\n\r]*SSH_ROUTER_PORT[^;\n\r]*["'\''])2026(["'\''])/${1}22${2}/g' "$f"

  # Ansible router ports should be 22.
  perl -0pi -e 's/(ansible_user=(?:net_admin|\$\{SSH_ROUTER_USER\}|"\$SSH_ROUTER_USER")[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
  perl -0pi -e 's/(ansible_port=)2026([^\n\r]*ansible_user=(?:net_admin|\$\{SSH_ROUTER_USER\}|"\$SSH_ROUTER_USER"))/${1}22${2}/g' "$f"

  # In case a generated inventory line hardcoded routers with port 2026.
  perl -0pi -e 's/(hq-rtr[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
  perl -0pi -e 's/(br-rtr[^\n\r]*ansible_port=)2026/${1}22/g' "$f"
}

# Patch all project source text files.
find . -type f \
  \( -name "*.sh" -o -name "*.env" -o -name "*.example" -o -name "*.md" -o -name "*.txt" -o -name "hosts" -o -name "config.env.example" \) \
  -not -path "./.git/*" \
  -not -path "./.patch_backups/*" \
  -not -path "./*.zip" \
  -not -path "./*.tar.gz" | while read -r f; do
    patch_text_file "${f#./}"
done

# Make sure config example has correct values even if it did not contain them.
if [ -f "config/config.env.example" ]; then
  backup_file "config/config.env.example"
  grep -q '^SSH_SERVER_PORT=' config/config.env.example && sed -i 's/^SSH_SERVER_PORT=.*/SSH_SERVER_PORT=2026/' config/config.env.example || echo 'SSH_SERVER_PORT=2026' >> config/config.env.example
  grep -q '^SSH_ROUTER_PORT=' config/config.env.example && sed -i 's/^SSH_ROUTER_PORT=.*/SSH_ROUTER_PORT=22/' config/config.env.example || echo 'SSH_ROUTER_PORT=22' >> config/config.env.example
  grep -q '^SSH_CLI_PORT=' config/config.env.example && sed -i 's/^SSH_CLI_PORT=.*/SSH_CLI_PORT=22/' config/config.env.example || echo 'SSH_CLI_PORT=22' >> config/config.env.example
  grep -q '^HQ_CLI_ANSIBLE_PORT=' config/config.env.example && sed -i 's/^HQ_CLI_ANSIBLE_PORT=.*/HQ_CLI_ANSIBLE_PORT=22/' config/config.env.example || echo 'HQ_CLI_ANSIBLE_PORT=22' >> config/config.env.example
fi

# Add a hard runtime guard at the start of likely entrypoints.
for mf in modules/initial_setup.sh modules/module2.sh modules/module3.sh; do
  if [ -f "$mf" ]; then
    backup_file "$mf"
    if ! grep -q 'router_ssh_port_guard_0_6_17' "$mf"; then
      tmp="$(mktemp)"
      {
        echo '# router_ssh_port_guard_0_6_17'
        echo 'SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"'
        echo 'if [ "$SSH_ROUTER_PORT" = "2026" ]; then SSH_ROUTER_PORT="22"; fi'
        echo
        cat "$mf"
      } > "$tmp"
      mv "$tmp" "$mf"
      chmod +x "$mf" 2>/dev/null || true
    fi
  fi
done

# Add runtime fix script to project.
mkdir -p modules
cat > modules/router_ssh_port_22_fix.sh <<'EOF'
#!/bin/bash
# Runtime guard: routers/client SSH=22, servers SSH=2026.

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"
mkdir -p /etc/demo-autoconfig "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }

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

log_ok "SSH ports fixed: servers=2026 routers=22 client=22"
EOF
chmod +x modules/router_ssh_port_22_fix.sh

# Make module2 and module3 call runtime fix before any SSH orchestration.
for mf in modules/module2.sh modules/module3.sh modules/initial_setup.sh; do
  if [ -f "$mf" ]; then
    backup_file "$mf"
    if ! grep -q 'router_ssh_port_22_fix.sh' "$mf"; then
      tmp="$(mktemp)"
      {
        echo 'if [ -f /opt/demo-autoconfig/modules/router_ssh_port_22_fix.sh ]; then'
        echo '  bash /opt/demo-autoconfig/modules/router_ssh_port_22_fix.sh'
        echo 'elif [ -f "$(dirname "$0")/router_ssh_port_22_fix.sh" ]; then'
        echo '  bash "$(dirname "$0")/router_ssh_port_22_fix.sh"'
        echo 'fi'
        echo
        cat "$mf"
      } > "$tmp"
      mv "$tmp" "$mf"
      chmod +x "$mf" 2>/dev/null || true
    fi
  fi
done

echo "$VERSION_VALUE" > VERSION

echo "[OK] Router SSH prompt/default fixed to 22"
echo "[OK] Backups saved to $BACKUP_DIR"
echo
echo "Check with:"
echo "grep -R \"Router SSH port\" -n modules lib config menu.sh 2>/dev/null"
echo "grep -R \"SSH_ROUTER_PORT\" -n modules lib config menu.sh 2>/dev/null"
