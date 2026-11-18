#!/usr/bin/env bash
#
# es-rolling-restart.sh — Rolling restart and node maintenance for a self-managed
#                         Elasticsearch 9.x cluster
#
# Commands:
#   restart          Full rolling restart of the cluster, one node at a time (default).
#   pre  <node>      Prepare a single node for maintenance (OS patching, reboot, ...):
#                      - verify the cluster is GREEN and no other maintenance is in progress
#                      - disable replica shard allocation (cluster.routing.allocation.enable = primaries)
#                      - flush all indices
#                      - stop the Elasticsearch service on the node and wait for it to leave
#                    On success the node can be patched and/or rebooted.
#   post <node>      Bring a node back after maintenance:
#                      - wait for the host to be reachable over SSH (it may still be rebooting)
#                      - start the Elasticsearch service if it is not already running
#                      - wait for the node to rejoin the cluster
#                      - re-enable shard allocation (cluster.routing.allocation.enable = null)
#                      - wait for the cluster to return to GREEN
#                    Only when 'post' succeeds is it safe to proceed with the next node.
#   order            Print the recommended maintenance order, one node per line
#                    ("<node_name> <host>"): non-master-eligible nodes first, then
#                    master-eligible nodes, and the elected master last.
#   status           Print cluster health, shard allocation setting and node list.
#
# Typical integration with a patching tool (Ansible, Satellite, ...), with serial: 1:
#   es-rolling-restart.sh order                 # determine the host order
#   for each node, strictly one at a time:
#     es-rolling-restart.sh pre  <node>         # abort the run if this fails
#     <patch the OS and reboot the host>
#     es-rolling-restart.sh post <node>         # abort the run if this fails
#
# Requirements: bash 4+, curl, jq, key-based SSH access to every node, and
#               passwordless sudo for systemctl on each node.
#
# Usage:
#   es-rolling-restart.sh [options] [restart | pre <node> | post <node> | order | status]
#
# Options:
#   -f, --force, -y, --yes   Skip the confirmation prompt of 'restart' (unattended execution)
#   -n, --dry-run            Print the planned actions without executing them
#   -e, --env-file PATH      Load configuration from PATH (default: .env next to the script)
#   -h, --help               Show this help and exit
#   'pre', 'post', 'order' and 'status' never prompt for confirmation.
#
# Exit codes:
#   0  Success
#   1  Error (timeout, SSH/API failure, cancelled by user)
#   2  Invalid arguments or configuration, or confirmation required but no TTY available
#   3  Precondition not met: the cluster is not GREEN, or another maintenance is in
#      progress (shard allocation is already restricted). Do not proceed with patching.
#
# Configuration file (.env):
#   Plain KEY=VALUE lines; comments (#) and blank lines are ignored. The file is
#   parsed, never executed, and only the variables listed under "Configuration"
#   are accepted. Variables already set in the environment take precedence.
#   The file must not be readable by group/others (chmod 600), as it may hold secrets.
#   Example:
#     ES_URL=https://es01:9200,https://es02:9200,https://es03:9200
#     ES_API_KEY_FILE=/etc/es-restart/es-api-key
#     ES_CACERT=/etc/es-restart/http_ca.crt
#     SSH_USER=esadmin
#
# Credentials:
#   Preferred: ES_API_KEY_FILE (or ES_PASS_FILE) pointing to a file that contains only
#   the secret, e.g. a systemd credential ($CREDENTIALS_DIRECTORY/es-api-key), a file
#   rendered by Vault Agent, or a CI/CD secret file. ES_API_KEY / ES_PASS are also
#   accepted. The *_FILE variants take precedence when both are set.
#   Secrets are never passed as command-line arguments: they are handed to curl
#   through standard input, so they are not exposed in the process list (ps).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Exit codes
readonly RC_ERROR=1 RC_USAGE=2 RC_PRECONDITION=3

# ----------------------------- Command-line arguments -------------------------
usage() { sed -n '3,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "$0"; }

CLI_FORCE=""; CLI_DRY_RUN=""
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
ENV_FILE_EXPLICIT=0
POSITIONAL=()
while (( $# > 0 )); do
  case "$1" in
    -f|--force|-y|--yes) CLI_FORCE=1 ;;
    -n|--dry-run)        CLI_DRY_RUN=1 ;;
    -e|--env-file)
      [[ $# -ge 2 ]] || { echo "Option $1 requires a file path" >&2; exit $RC_USAGE; }
      ENV_FILE="$2"; ENV_FILE_EXPLICIT=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*) echo "Unknown option: $1 (use --help)" >&2; exit $RC_USAGE ;;
    *)  POSITIONAL+=("$1") ;;
  esac
  shift
done

COMMAND="${POSITIONAL[0]:-restart}"
TARGET_NODE="${POSITIONAL[1]:-}"
case "$COMMAND" in
  restart|order|status)
    (( ${#POSITIONAL[@]} <= 1 )) || { echo "Command '${COMMAND}' takes no arguments" >&2; exit $RC_USAGE; } ;;
  pre|post)
    [[ -n "$TARGET_NODE" && ${#POSITIONAL[@]} -eq 2 ]] \
      || { echo "Usage: $(basename "$0") ${COMMAND} <node_name>" >&2; exit $RC_USAGE; } ;;
  *) echo "Unknown command: ${COMMAND} (use --help)" >&2; exit $RC_USAGE ;;
esac

# ----------------------------- Configuration file -----------------------------
ALLOWED_VARS=" ES_URL ES_USER ES_PASS ES_PASS_FILE ES_API_KEY ES_API_KEY_FILE ES_CACERT INSECURE
  NODES SSH_USER SSH_OPTS SSH_HOST_FROM SERVICE WAIT_LEAVE_TIMEOUT WAIT_NODE_TIMEOUT
  WAIT_SSH_TIMEOUT WAIT_GREEN_TIMEOUT POLL DRY_RUN FORCE POST_START "

load_env_file() {
  local file="$1" line key value perms lineno=0
  # Refuse files readable by group or others, since they may contain credentials
  perms="$(stat -c '%a' "$file")"
  if (( 8#$perms & 8#077 )); then
    echo "ERROR: ${file} has permissions ${perms}; restrict them with: chmod 600 ${file}" >&2
    exit $RC_USAGE
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      echo "ERROR: ${file}:${lineno}: invalid syntax (expected KEY=VALUE)" >&2; exit $RC_USAGE
    fi
    key="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
    [[ "$ALLOWED_VARS" == *" ${key} "* || "$ALLOWED_VARS" == *" ${key}"$'\n'* ]] \
      || { echo "ERROR: ${file}:${lineno}: unknown variable '${key}'" >&2; exit $RC_USAGE; }
    # Strip matching surrounding quotes
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    # Environment variables take precedence over the file
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$value"
  done < "$file"
}

if [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
elif (( ENV_FILE_EXPLICIT )); then
  echo "ERROR: configuration file not found: ${ENV_FILE}" >&2; exit $RC_USAGE
fi

# ----------------------------- Configuration ---------------------------------
ES_URL="${ES_URL:-https://localhost:9200}"   # one or more nodes: "https://es01:9200,https://es02:9200"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS:-}"                        # alternatively, set ES_API_KEY
ES_PASS_FILE="${ES_PASS_FILE:-}"              # file containing the password (preferred over ES_PASS)
ES_API_KEY="${ES_API_KEY:-}"                  # encoded API key, without the "ApiKey " prefix
ES_API_KEY_FILE="${ES_API_KEY_FILE:-}"        # file containing the API key (preferred over ES_API_KEY)
ES_CACERT="${ES_CACERT:-/etc/elasticsearch/certs/http_ca.crt}"  # leave empty and set INSECURE=1 to use -k
INSECURE="${INSECURE:-0}"

NODES="${NODES:-}"                 # 'restart' only: space-separated node names; empty = all nodes
SSH_USER="${SSH_USER:-${USER:-$(id -un)}}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10}"
SSH_HOST_FROM="${SSH_HOST_FROM:-ip}"           # 'ip' or 'name': attribute used as the SSH target host
SERVICE="${SERVICE:-elasticsearch}"
POST_START="${POST_START:-1}"                  # 'post': start the service if it is not running

WAIT_LEAVE_TIMEOUT="${WAIT_LEAVE_TIMEOUT:-300}"  # seconds to wait for a stopped node to leave the cluster
WAIT_SSH_TIMEOUT="${WAIT_SSH_TIMEOUT:-1800}"     # 'post': seconds to wait for the host to accept SSH
WAIT_NODE_TIMEOUT="${WAIT_NODE_TIMEOUT:-1800}"   # seconds to wait for a node to rejoin the cluster
WAIT_GREEN_TIMEOUT="${WAIT_GREEN_TIMEOUT:-3600}" # seconds to wait for the cluster to return to green
POLL="${POLL:-10}"                               # polling interval in seconds
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"                              # 1 = skip the confirmation prompt
# -----------------------------------------------------------------------------

# Command-line flags override both the environment and the .env file
[[ -n "$CLI_FORCE" ]]   && FORCE="$CLI_FORCE"
[[ -n "$CLI_DRY_RUN" ]] && DRY_RUN="$CLI_DRY_RUN"

# ----------------------------- Helpers ----------------------------------------
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "${2:-INFO}" "$1" >&2; }
die()  { log "$1" ERROR; exit "${2:-$RC_ERROR}"; }

for bin in curl jq ssh; do command -v "$bin" >/dev/null || die "Required command not found: '$bin'" $RC_USAGE; done

# ----------------------------- Credentials ------------------------------------
read_secret_file() {  # read_secret_file <path> <var>: store the secret, trimmed, in <var>
  local file="$1" var="$2" perms secret
  [[ -r "$file" ]] || die "Secret file not found or not readable: ${file}" $RC_USAGE
  perms="$(stat -L -c '%a' "$file")"
  if (( 8#$perms & 8#007 )); then
    die "Secret file ${file} is readable by others (mode ${perms}); restrict it with: chmod 600 ${file}" $RC_USAGE
  fi
  secret="$(<"$file")"
  secret="${secret#"${secret%%[![:space:]]*}"}"   # trim leading whitespace
  secret="${secret%"${secret##*[![:space:]]}"}"   # trim trailing whitespace/newlines
  [[ -n "$secret" ]] || die "Secret file is empty: ${file}" $RC_USAGE
  printf -v "$var" '%s' "$secret"
}

curl_cfg_escape() {  # escape a value for a curl config file (backslashes and double quotes)
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

if [[ -n "$ES_API_KEY_FILE" ]]; then read_secret_file "$ES_API_KEY_FILE" ES_API_KEY; fi
if [[ -n "$ES_PASS_FILE" ]];    then read_secret_file "$ES_PASS_FILE" ES_PASS; fi

# Authentication is supplied to curl as a config read from stdin (-K -), so the
# secret never appears in the process arguments.
CURL_AUTH_CONFIG=""
if [[ -n "$ES_API_KEY" ]]; then
  CURL_AUTH_CONFIG="header = \"Authorization: ApiKey $(curl_cfg_escape "$ES_API_KEY")\""
  AUTH_METHOD="API key"
elif [[ -n "$ES_PASS" ]]; then
  CURL_AUTH_CONFIG="user = \"$(curl_cfg_escape "${ES_USER}:${ES_PASS}")\""
  AUTH_METHOD="basic authentication (user '${ES_USER}')"
else
  AUTH_METHOD="none"
fi
# Remove plain-text secrets from the shell environment so child processes (ssh) do not inherit them
unset ES_API_KEY ES_PASS

CURL_ARGS=(-sS --fail-with-body -H 'Content-Type: application/json')
if [[ "$INSECURE" == "1" ]]; then
  CURL_ARGS+=(-k)
elif [[ -n "$ES_CACERT" && -f "$ES_CACERT" ]]; then
  CURL_ARGS+=(--cacert "$ES_CACERT")
fi

# ----------------------------- Elasticsearch API ------------------------------
# es METHOD PATH [BODY]
# ES_URL accepts a comma-separated list of URLs. If a node is unavailable
# (e.g. the node under maintenance or the former master), the next URL is tried.
IFS=',' read -r -a ES_URLS <<< "$ES_URL"
es() {
  local method="$1" path="$2" body="${3:-}" url
  local args=("${CURL_ARGS[@]}" -X "$method")
  [[ -n "$body" ]] && args+=(-d "$body")
  for url in "${ES_URLS[@]}"; do
    if curl -K - "${args[@]}" --connect-timeout 5 "${url}${path}" <<< "$CURL_AUTH_CONFIG"; then return 0; fi
  done
  return 1
}

run() {  # execute the command, or only log it when DRY_RUN=1
  if [[ "$DRY_RUN" == "1" ]]; then log "DRY-RUN: $*" DRY; else "$@"; fi
}

cluster_status() { es GET '/_cluster/health?filter_path=status' | jq -r '.status'; }
is_green()       { [[ "$(cluster_status 2>/dev/null)" == "green" ]]; }

# Current value of cluster.routing.allocation.enable (transient overrides persistent; default 'all')
allocation_setting() {
  es GET '/_cluster/settings?filter_path=*.cluster.routing.allocation.enable&flat_settings=true' \
    | jq -r '.transient["cluster.routing.allocation.enable"]
             // .persistent["cluster.routing.allocation.enable"] // "all"'
}

ALLOCATION_CHANGED=0
set_allocation() {  # primaries | null
  local value="$1" json
  [[ "$value" == "null" ]] && json='null' || json="\"$value\""
  log "Setting shard allocation to: ${value}"
  run es PUT /_cluster/settings \
    "{\"persistent\":{\"cluster.routing.allocation.enable\":${json}}}" >/dev/null
  [[ "$value" == "primaries" ]] && ALLOCATION_CHANGED=1 || ALLOCATION_CHANGED=0
}

# Node table: name, ip, roles, master ('*' denotes the elected master)
node_table()     { es GET '/_cat/nodes?h=name,ip,node.role,master&format=json'; }
elected_master() { es GET '/_cat/master?h=node' | awk '{print $1}'; }

node_in_cluster() {
  es GET '/_cat/nodes?h=name' 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}
node_left() { ! node_in_cluster "$1"; }

is_master_eligible() {  # role 'm' present in node.role
  echo "$NODE_TABLE" | jq -e --arg n "$1" \
    '.[] | select(.name==$n) | ."node.role" | contains("m")' >/dev/null
}

# Priority: 0 = not master-eligible, 1 = master-eligible, 2 = elected master
node_priority() {
  if [[ "$1" == "$CURRENT_MASTER" ]]; then echo 2
  elif is_master_eligible "$1"; then echo 1
  else echo 0; fi
}

role_label() {
  case "$(node_priority "$1")" in
    0) echo "data/other" ;;
    1) echo "master-eligible" ;;
    2) echo "ELECTED MASTER" ;;
  esac
}

# SSH target for a node, resolved from the cluster while the node is still a member
node_host() {
  echo "$NODE_TABLE" | jq -r --arg n "$1" ".[] | select(.name==\$n) | .${SSH_HOST_FROM}"
}

wait_for() {  # wait_for <timeout> <description> <command...>
  local timeout="$1" desc="$2"; shift 2
  local start=$SECONDS
  until "$@"; do
    (( SECONDS - start >= timeout )) && die "Timed out after ${timeout}s waiting for: ${desc}"
    sleep "$POLL"
  done
}

ssh_node() {  # ssh_node <host> <command>: executed (or logged in dry-run mode)
  local host="$1"; shift
  # shellcheck disable=SC2086
  run ssh $SSH_OPTS "${SSH_USER}@${host}" "$@"
}

ssh_query() {  # ssh_query <host> <command>: read-only, always executed (also in dry-run)
  local host="$1"; shift
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "${SSH_USER}@${host}" "$@"
}

ssh_reachable() { ssh_query "$1" true >/dev/null 2>&1; }

# On abnormal termination, warn if shard allocation may have been left restricted
on_exit() {
  local rc=$?
  if (( rc != 0 && rc != RC_USAGE && rc != RC_PRECONDITION )); then
    log "Script terminated with an error (rc=$rc). Please verify the cluster state." WARN
    [[ "$ALLOCATION_CHANGED" == "1" ]] || return 0
    log "Shard allocation may still be restricted to primaries." WARN
    log "Once the node is back, run '$(basename "$0") post <node>' or re-enable allocation with:" WARN
    log "  PUT _cluster/settings {\"persistent\":{\"cluster.routing.allocation.enable\":null}}" WARN
  fi
}
trap on_exit EXIT

# ----------------------------- Common checks ----------------------------------
connect() {
  log "Connecting to ${ES_URL} (authentication: ${AUTH_METHOD})"
  local info
  info="$(es GET /)" || die "Unable to connect to Elasticsearch"
  log "$(jq -r '"Cluster: \(.cluster_name)  Version: \(.version.number)"' <<< "$info")"
  NODE_TABLE="$(node_table)"
  CURRENT_MASTER="$(elected_master)"
}

# Preconditions for taking a node down: cluster GREEN and no other maintenance in progress
require_safe_to_start() {
  local status alloc
  status="$(cluster_status)"
  [[ "$status" == "green" ]] \
    || die "Cluster health is '${status}'. It must be GREEN before taking a node down." $RC_PRECONDITION
  alloc="$(allocation_setting)"
  [[ "$alloc" == "all" ]] \
    || die "Shard allocation is '${alloc}': another maintenance appears to be in progress (or a previous one did not complete). Finish it with 'post <node>' first." $RC_PRECONDITION
}

require_node_known() {
  echo "$NODE_TABLE" | jq -e --arg n "$1" 'any(.[]; .name==$n)' >/dev/null \
    || die "Node '$1' is not a member of the cluster. Known nodes: $(echo "$NODE_TABLE" | jq -r '[.[].name] | join(", ")')" $RC_PRECONDITION
}

# ----------------------------- Node phases ------------------------------------
# Phase 1: take a node out of service (allocation, flush, stop)
node_pre() {
  local node="$1" host="$2" enabled
  require_safe_to_start

  if [[ "$node" == "$CURRENT_MASTER" ]]; then
    log "Node ${node} is the ELECTED MASTER: a new master election will take place (a few seconds)." WARN
    log "It is recommended to process the elected master last (see the 'order' command)." WARN
  fi

  # A reboot only brings Elasticsearch back if the service is enabled at boot
  enabled="$(ssh_query "$host" "systemctl is-enabled ${SERVICE} 2>/dev/null || true")" \
    || die "Unable to connect to ${host} over SSH"
  if [[ "$enabled" != "enabled" ]]; then
    if [[ "$POST_START" == "1" ]]; then
      log "Service ${SERVICE} is '${enabled:-unknown}' on ${host}: it will not start automatically after a reboot; 'post' will start it." WARN
    else
      die "Service ${SERVICE} is '${enabled:-unknown}' on ${host} and POST_START=0: the node would not come back after a reboot." $RC_PRECONDITION
    fi
  fi

  # 1. Disable replica shard allocation
  set_allocation primaries

  # 2. Flush indices (speeds up shard recovery). A failure at this step is not fatal.
  log "Flushing indices"
  run es POST /_flush >/dev/null || log "Flush returned errors; continuing" WARN

  # 3. Stop the node and wait for it to leave the cluster
  log "Stopping ${SERVICE} on ${host}"
  ssh_node "$host" "sudo systemctl stop ${SERVICE}"
  if [[ "$DRY_RUN" != "1" ]]; then
    wait_for "$WAIT_LEAVE_TIMEOUT" "node ${node} to leave the cluster" node_left "$node"
    log "Node ${node} has left the cluster"
  fi
}

# Phase 2: bring a node back into service (start, rejoin, allocation, green)
node_post() {
  local node="$1" host="$2"

  if node_in_cluster "$node"; then
    log "Node ${node} is already a member of the cluster"
  else
    if [[ "$POST_START" == "1" ]]; then
      # The host may still be rebooting after patching
      log "Waiting for ${host} to accept SSH connections..."
      [[ "$DRY_RUN" == "1" ]] || wait_for "$WAIT_SSH_TIMEOUT" "SSH on ${host}" ssh_reachable "$host"
      log "Starting ${SERVICE} on ${host} (no-op if already running)"
      ssh_node "$host" "sudo systemctl start ${SERVICE}"
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
      log "Waiting for node ${node} to rejoin the cluster..."
      wait_for "$WAIT_NODE_TIMEOUT" "node ${node} to rejoin the cluster" node_in_cluster "$node"
      log "Node ${node} has rejoined the cluster"
    fi
  fi

  # Re-enable shard allocation
  set_allocation null

  # Wait for GREEN status before any other node may be taken down
  if [[ "$DRY_RUN" != "1" ]]; then
    log "Waiting for cluster health to return to GREEN..."
    wait_for "$WAIT_GREEN_TIMEOUT" "cluster health to be green" is_green
    log "Cluster health is GREEN"
  fi
}

# Remembers the SSH host of a node between 'pre' and 'post', since the node is not
# in the cluster (and its IP cannot be resolved from it) while under maintenance.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/es-rolling-restart"
remember_host() { mkdir -p "$STATE_DIR" && printf '%s\n' "$2" > "${STATE_DIR}/$1.host"; }
recall_host()   { [[ -f "${STATE_DIR}/$1.host" ]] && cat "${STATE_DIR}/$1.host"; }
forget_host()   { rm -f "${STATE_DIR}/$1.host"; }

# ----------------------------- Commands ---------------------------------------
cmd_status() {
  connect
  log "Cluster health: $(cluster_status)"
  log "Shard allocation: $(allocation_setting)"
  log "Elected master: ${CURRENT_MASTER}"
  echo "$NODE_TABLE" | jq -r '.[] | "\(.name)\t\(.ip)\t\(."node.role")\t\(.master)"' \
    | sort | while IFS=$'\t' read -r n ip roles m; do
        log "  ${n}  ${ip}  roles=${roles}  $( [[ "$m" == "*" ]] && echo "(elected master)")"
      done
}

cmd_order() {
  connect
  # Not master-eligible first, then master-eligible, elected master last; ties by name
  echo "$NODE_TABLE" | jq -r --arg host "$SSH_HOST_FROM" '
    sort_by((if .master == "*" then 2 elif (."node.role" | contains("m")) then 1 else 0 end), .name)
    | .[] | "\(.name) \(.[$host])"'
}

cmd_pre() {
  local node="$1" host
  connect
  require_node_known "$node"
  host="$(node_host "$node")"
  log "========== PRE-MAINTENANCE: node ${node} (${host}) — $(role_label "$node") =========="
  node_pre "$node" "$host"
  [[ "$DRY_RUN" == "1" ]] || remember_host "$node" "$host"
  log "Node ${node} is out of service. It is now safe to patch and/or reboot ${host}."
  log "When maintenance is complete, run: $(basename "$0") post ${node}"
}

cmd_post() {
  local node="$1" host
  connect
  if node_in_cluster "$node"; then
    host="$(node_host "$node")"
  else
    host="$(recall_host "$node" || true)"
    [[ -n "$host" ]] || die "Node '${node}' is not in the cluster and its host is unknown (was 'pre' run from this machine?)." $RC_PRECONDITION
  fi
  log "========== POST-MAINTENANCE: node ${node} (${host}) =========="
  ALLOCATION_CHANGED=1   # allocation is expected to be restricted until this phase completes
  node_post "$node" "$host"
  [[ "$DRY_RUN" == "1" ]] || forget_host "$node"
  log "Node ${node} is back in service and the cluster is GREEN. It is safe to proceed with the next node."
}

cmd_restart() {
  POST_START=1   # in a plain restart the script itself always starts the service again
  connect
  local -a pending
  if [[ -z "$NODES" ]]; then
    mapfile -t pending < <(echo "$NODE_TABLE" | jq -r '.[].name' | sort)
  else
    read -r -a pending <<< "$NODES"
  fi

  log "Current elected master: ${CURRENT_MASTER}"
  log "Nodes to be restarted:"
  local n
  for n in "${pending[@]}"; do
    require_node_known "$n"
    log "  ${n}: $(role_label "$n")$( [[ "$n" == "$CURRENT_MASTER" ]] && echo " (will be restarted last)")"
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Dry-run mode: no changes will be applied"
  elif [[ "$FORCE" == "1" ]]; then
    log "Force mode enabled: proceeding without confirmation" WARN
  elif [[ -t 0 ]]; then
    read -r -p "Proceed with the rolling restart? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "Operation cancelled by user"
  else
    die "No interactive terminal detected. Use --force (or FORCE=1) for unattended execution." $RC_USAGE
  fi

  local total=${#pending[@]} i=0 node host best best_p p idx
  while (( ${#pending[@]} > 0 )); do
    # Refresh cluster state: the elected master may have changed
    NODE_TABLE="$(node_table)"
    CURRENT_MASTER="$(elected_master)"

    # Select the pending node with the lowest priority (elected master always last)
    best=""; best_p=99
    for n in "${pending[@]}"; do
      p="$(node_priority "$n")"
      if (( p < best_p )); then best="$n"; best_p=$p; fi
    done
    node="$best"
    for idx in "${!pending[@]}"; do
      [[ "${pending[$idx]}" == "$node" ]] && unset 'pending[idx]'
    done
    pending=("${pending[@]}")

    if [[ "$node" == "$CURRENT_MASTER" && ${#pending[@]} -gt 0 ]]; then
      die "Refusing to restart the elected master while nodes are still pending: ${pending[*]}"
    fi

    i=$((i+1))
    host="$(node_host "$node")"
    [[ -n "$host" && "$host" != "null" ]] || die "Node '${node}' not found in the cluster"
    log "========== [${i}/${total}] Node ${node} (${host}) — $(role_label "$node") =========="

    node_pre  "$node" "$host"
    node_post "$node" "$host"
  done

  log "Rolling restart completed successfully (${total} nodes)."
}

# ----------------------------- Main -------------------------------------------
case "$COMMAND" in
  restart) cmd_restart ;;
  pre)     cmd_pre  "$TARGET_NODE" ;;
  post)    cmd_post "$TARGET_NODE" ;;
  order)   cmd_order ;;
  status)  cmd_status ;;
esac
