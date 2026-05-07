#!/usr/bin/env bash

cleanup_temporary_files() {
  local target="${DEMO_BOOTSTRAP_TMP:-/tmp/demo-autoconfig}"
  if [ "$target" != "/tmp/demo-autoconfig" ]; then
    log_warn "Unexpected temp directory: $target"
    return 1
  fi
  rm -rf "$target"
  log_ok "Temporary files removed: $target"
}
