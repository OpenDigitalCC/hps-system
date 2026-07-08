# shellcheck shell=bash
# n_ctrl-exec.sh
#
# Node-side ctrl-exec agent lifecycle: install, configure, start, pair, renew.
# Delivered in the node function bundle. See:
#   docs/adr/0001-orchestration-split.md
#   docs/adr/0002-ctrl-exec-enrolment-trust.md
#   docs/adr/0003-ctrl-exec-agent-packaging.md
#
# The IPS runs the dispatcher and CA; each node runs the Perl mTLS agent on
# 7443. Enrolment is hands-free: the node requests pairing in the background,
# reports its reqid to the IPS over the HPS API, and the IPS-side registry-bound
# approver decides. All later IPS->node execution is over mTLS via the hps-node
# plugin.

# Floating tarball name served from the IPS package repo. The IPS maintains a
# stable 'ctrl-exec-latest.tar.gz' symlink to the current release so nodes are
# not pinned to a version string (see feedback: avoid version pinning).
: "${CTRL_EXEC_TARBALL:=ctrl-exec-latest.tar.gz}"
# Where on the node the agent's cert and config live (upstream defaults).
: "${CTRL_EXEC_AGENT_ETC:=/etc/ctrl-exec-agent}"
: "${CTRL_EXEC_AGENT_LIB:=/var/lib/ctrl-exec-agent}"
# Node-side pairing wait, seconds. Matches the IPS pairing window.
: "${CTRL_EXEC_PAIR_TIMEOUT:=300}"

#===============================================================================
# n_install_ctrl_exec
# -------------------
# Install the ctrl-exec agent and its runtime dependencies on this node.
# Alpine: deps from the HPS-mirrored repo, agent from the HPS-served tarball.
# Rocky: same tarball path (no upstream rpm yet - ADR 0003).
#
# Returns: 0 on success, non-zero on failure.
#===============================================================================
n_install_ctrl_exec() {
  n_remote_log "[ctrl-exec] Installing agent and dependencies"

  # Runtime dependencies: Perl agent + IO::Socket::SSL + JSON + openssl CLI.
  if [[ -f /etc/alpine-release ]]; then
    n_install_packages perl perl-io-socket-ssl perl-json openssl || {
      n_remote_log "[ctrl-exec] ERROR: failed to install Alpine dependencies"
      return 1
    }
  elif [[ -f /etc/rocky-release ]] || [[ -f /etc/redhat-release ]]; then
    n_remote_log "[ctrl-exec] Rocky dependency install via dnf"
    dnf install -y perl perl-IO-Socket-SSL perl-JSON openssl || {
      n_remote_log "[ctrl-exec] ERROR: failed to install Rocky dependencies"
      return 1
    }
  else
    n_remote_log "[ctrl-exec] ERROR: unknown OS, cannot install dependencies"
    return 1
  fi

  # Fetch and unpack the agent tarball from the IPS package repo.
  local ips tar_url work
  ips="$(n_get_provisioning_node)" || {
    n_remote_log "[ctrl-exec] ERROR: cannot determine IPS address"
    return 1
  }
  tar_url="http://${ips}/packages/ctrl-exec/${CTRL_EXEC_TARBALL}"
  work="/tmp/ctrl-exec-install.$$"
  mkdir -p "$work" || return 1

  if ! curl -fsSL "$tar_url" -o "$work/ctrl-exec.tar.gz"; then
    n_remote_log "[ctrl-exec] ERROR: cannot fetch tarball from $tar_url"
    rm -rf "$work"
    return 1
  fi
  if ! tar -xzf "$work/ctrl-exec.tar.gz" -C "$work"; then
    n_remote_log "[ctrl-exec] ERROR: cannot unpack tarball"
    rm -rf "$work"
    return 1
  fi

  # Upstream install.sh handles Alpine apk / user creation; run it agent-only.
  local srcdir
  srcdir="$(find "$work" -maxdepth 1 -type d -name 'ctrl-exec-*' | head -n1)"
  if [[ -n "$srcdir" && -x "$srcdir/install.sh" ]]; then
    ( cd "$srcdir" && ./install.sh --agent ) || {
      n_remote_log "[ctrl-exec] ERROR: upstream install.sh failed"
      rm -rf "$work"
      return 1
    }
  else
    n_remote_log "[ctrl-exec] ERROR: install.sh not found in tarball"
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"

  # Install the hps-node plugin (the single allowlisted entry point).
  n_ctrl_exec_install_plugin || return 1
  # Write agent + allowlist config.
  n_ctrl_exec_write_config || return 1
  # Install the OpenRC service on Alpine (upstream ships none).
  if [[ -f /etc/alpine-release ]]; then
    n_ctrl_exec_install_openrc || return 1
  fi

  n_remote_log "[ctrl-exec] Agent installed"
  return 0
}

#===============================================================================
# n_ctrl_exec_install_plugin
# --------------------------
# Fetch the hps-node plugin from the IPS and install it as the single
# allowlisted script.
#===============================================================================
n_ctrl_exec_install_plugin() {
  local ips
  ips="$(n_get_provisioning_node)" || return 1
  if ! curl -fsSL "http://${ips}/cgi-bin/boot_manager.sh?cmd=get_node_plugin&name=hps-node" \
        -o /usr/local/sbin/hps-node; then
    n_remote_log "[ctrl-exec] ERROR: cannot fetch hps-node plugin"
    return 1
  fi
  chmod 0750 /usr/local/sbin/hps-node
  return 0
}

#===============================================================================
# n_ctrl_exec_write_config
# ------------------------
# Write agent.conf and the scripts.conf allowlist (hps-node only).
#===============================================================================
n_ctrl_exec_write_config() {
  mkdir -p "$CTRL_EXEC_AGENT_ETC" || return 1

  # Minimal agent config: serve on the default operational port; the executor
  # is deferred (ADR 0003) so scripts run as the agent user.
  cat > "$CTRL_EXEC_AGENT_ETC/agent.conf" <<'EOF'
# HPS-managed ctrl-exec agent config. Regenerated on each provisioning cycle.
listen_port = 7443
EOF

  cat > "$CTRL_EXEC_AGENT_ETC/scripts.conf" <<'EOF'
# HPS node operations entry point. The subcommand allowlist lives inside the
# script (see node-manager/plugins/hps-node); this file exposes only the one
# name to ctrl-exec.
hps-node = /usr/local/sbin/hps-node
EOF
  return 0
}

#===============================================================================
# n_ctrl_exec_install_openrc
# --------------------------
# Install an OpenRC service for the agent (Alpine). Upstream ships only
# systemd/procd units (ADR 0003).
#===============================================================================
n_ctrl_exec_install_openrc() {
  cat > /etc/init.d/ctrl-exec-agent <<'EOF'
#!/sbin/openrc-run
# HPS-supplied OpenRC service for the ctrl-exec agent (Alpine has no upstream
# unit). Promotes any staged renewed cert at start, then serves.

name="ctrl-exec-agent"
description="ctrl-exec mTLS remote execution agent"
command="/usr/bin/ctrl-exec-agent"
command_args="serve"
command_background="yes"
pidfile="/run/ctrl-exec-agent.pid"
output_log="/var/log/ctrl-exec-agent.log"
error_log="/var/log/ctrl-exec-agent.log"

depend() {
    need net
    after firewall
}

start_pre() {
    # Adopt a staged renewed certificate before serving (no systemd timer on
    # OpenRC - ADR 0003). Non-fatal if there is nothing to promote.
    /usr/bin/ctrl-exec-agent promote-cert 2>/dev/null || true
}
EOF
  chmod 0755 /etc/init.d/ctrl-exec-agent
  rc-update add ctrl-exec-agent default 2>/dev/null || true
  return 0
}

#===============================================================================
# n_ctrl_exec_start
# -----------------
# Start (or restart) the agent.
#===============================================================================
n_ctrl_exec_start() {
  n_remote_log "[ctrl-exec] Starting agent"
  if [[ -f /etc/alpine-release ]]; then
    rc-service ctrl-exec-agent restart || {
      n_remote_log "[ctrl-exec] ERROR: rc-service start failed"
      return 1
    }
  else
    systemctl restart ctrl-exec-agent || {
      n_remote_log "[ctrl-exec] ERROR: systemctl start failed"
      return 1
    }
  fi
  return 0
}

#===============================================================================
# n_ctrl_exec_pair
# ----------------
# Hands-free enrolment: request pairing in the background, report the reqid to
# the IPS for registry-bound approval, and wait for the signed cert.
#
# Returns: 0 once paired, non-zero on failure or timeout.
#===============================================================================
n_ctrl_exec_pair() {
  local ips reqid
  ips="$(n_get_provisioning_node)" || {
    n_remote_log "[ctrl-exec] ERROR: cannot determine IPS address"
    return 1
  }

  # Already paired (e.g. re-run within a cycle): nothing to do.
  if [[ -s "$CTRL_EXEC_AGENT_ETC/agent.crt" ]]; then
    n_remote_log "[ctrl-exec] Already holds a certificate; skipping pairing"
    return 0
  fi

  n_remote_log "[ctrl-exec] Requesting pairing from $ips"
  # --background prints the reqid and detaches the approval wait.
  reqid="$(ctrl-exec-agent request-pairing --background \
            --timeout "$CTRL_EXEC_PAIR_TIMEOUT" --dispatcher "$ips" 2>/dev/null)" || {
    n_remote_log "[ctrl-exec] ERROR: request-pairing failed"
    return 1
  }
  reqid="$(printf '%s' "$reqid" | tr -dc 'a-f0-9')"
  if [[ -z "$reqid" ]]; then
    n_remote_log "[ctrl-exec] ERROR: no reqid returned from pairing request"
    return 1
  fi

  # Report the reqid to the IPS; the registry-bound approver decides.
  n_remote_log "[ctrl-exec] Reporting reqid $reqid to IPS"
  if ! n_api_request ctrl_exec_pair_request "reqid=$reqid" >/dev/null; then
    n_remote_log "[ctrl-exec] ERROR: IPS declined the pairing request"
    return 1
  fi

  # Wait for the agent's background pairing to write the cert.
  local waited=0
  while (( waited < CTRL_EXEC_PAIR_TIMEOUT )); do
    if [[ -s "$CTRL_EXEC_AGENT_ETC/agent.crt" ]]; then
      n_remote_log "[ctrl-exec] Paired (certificate received)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  n_remote_log "[ctrl-exec] ERROR: pairing timed out after ${CTRL_EXEC_PAIR_TIMEOUT}s"
  return 1
}

#===============================================================================
# n_ctrl_exec_enrol
# -----------------
# One-shot enrolment: install, start, pair. Idempotent per boot cycle so it is
# safe on diskless nodes that rebuild their root each boot (ADR 0003).
#===============================================================================
n_ctrl_exec_enrol() {
  n_install_ctrl_exec || return 1
  n_ctrl_exec_start || return 1
  n_ctrl_exec_pair || return 1
  return 0
}
