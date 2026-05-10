if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/usr/bin/env bash

prompt_default() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local value
  if [ -n "$default" ]; then
    read -r -p "$question [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$question: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_required() {
  local var_name="$1"
  local question="$2"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$question: " value
  done
  printf -v "$var_name" '%s' "$value"
}

prompt_choice() {
  local var_name="$1"
  local question="$2"
  shift 2
  local choices="$*"
  local value
  while true; do
    read -r -p "$question ($choices): " value
    for choice in "$@"; do
      if [ "$value" = "$choice" ]; then
        printf -v "$var_name" '%s' "$value"
        return 0
      fi
    done
    printf '[WARN] Allowed values: %s\n' "$choices"
  done
}
