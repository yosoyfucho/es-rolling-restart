# es-rolling-restart

Automates rolling restarts and per-node maintenance (OS patching, reboots) of a
self-managed **Elasticsearch 9.x** cluster, following the procedure recommended
by Elastic. It replaces the manual steps otherwise performed in Kibana Dev Tools
(disabling shard allocation, flushing, re-enabling allocation and monitoring
cluster health).

The script runs from a **central administration host** (bastion, Ansible
controller, CI runner). It talks to the Elasticsearch REST API over HTTPS and
connects to each node over SSH only to stop and start the Elasticsearch service.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Commands](#commands)
- [Patching workflow (pre / post)](#patching-workflow-pre--post)
- [Full rolling restart](#full-rolling-restart)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)
- [Safety notes](#safety-notes)

---

## How it works

For every node, strictly one at a time:

| Step | Action | API / command |
|------|--------|---------------|
| 1 | Verify the cluster is GREEN and no other maintenance is in progress | `GET _cluster/health`, `GET _cluster/settings` |
| 2 | Disable replica shard allocation | `PUT _cluster/settings` → `cluster.routing.allocation.enable: primaries` |
| 3 | Flush all indices (faster shard recovery) | `POST _flush` |
| 4 | Stop Elasticsearch and wait for the node to leave the cluster | `sudo systemctl stop elasticsearch` |
| 5 | *(Maintenance window: patching, reboot, etc.)* | — |
| 6 | Wait for the host to be reachable, start Elasticsearch if needed and wait for the node to rejoin | `sudo systemctl start elasticsearch` |
| 7 | Re-enable shard allocation | `PUT _cluster/settings` → `cluster.routing.allocation.enable: null` |
| 8 | Wait for the cluster to return to GREEN before the next node | `GET _cluster/health` |

**Node order.** Non-master-eligible nodes (data, ingest, etc.) are processed
first, then master-eligible nodes, and the **elected master always last**. This
minimises the number of master elections. The order is re-evaluated before each
node, since the elected master may change during the process.

There are no fixed waits: each step waits exactly as long as needed, up to a
configurable maximum (see [Timeouts](#timeouts)). The script never moves on to
the next node until the cluster is GREEN again.

---

## Requirements

### Administration host

- Linux with `bash` 4+, `curl` and `jq`
- Network access to the Elasticsearch HTTP port (default 9200) of the nodes,
  or to a load balancer in front of them
- Key-based SSH access to every node
- The cluster CA certificate (e.g. `http_ca.crt`)

### Elasticsearch nodes

- Elasticsearch managed by systemd (service name configurable, default `elasticsearch`)
- The service **enabled at boot** (`systemctl enable elasticsearch`) if hosts are
  rebooted during maintenance. Otherwise `post` will start it explicitly.
- Passwordless sudo for the SSH user, restricted to the required commands:

  ```
  # /etc/sudoers.d/es-rolling-restart
  esadmin ALL=(root) NOPASSWD: /usr/bin/systemctl stop elasticsearch, /usr/bin/systemctl start elasticsearch
  ```

### Elasticsearch privileges

Use a dedicated API key with the minimum privileges required and an expiration date:

```json
POST /_security/api_key
{
  "name": "es-rolling-restart",
  "expiration": "90d",
  "role_descriptors": {
    "es_rolling_restart": {
      "cluster": ["monitor", "manage"],
      "indices": [
        { "names": ["*"], "privileges": ["maintenance"] }
      ]
    }
  }
}
```

| Privilege | Used for |
|-----------|----------|
| `monitor` (cluster) | Cluster health, node list, elected master |
| `manage` (cluster) | Updating `cluster.routing.allocation.enable` |
| `maintenance` (indices) | `POST _flush` |

Store only the `encoded` value from the response; it is the value the script expects.

---

## Installation

```bash
sudo mkdir -p /opt/es-tools /etc/es-restart
sudo cp es-rolling-restart.sh .env.example /opt/es-tools/
sudo chmod 750 /opt/es-tools/es-rolling-restart.sh

# API key (only the "encoded" value, nothing else)
sudo install -m 600 -o esadmin /dev/null /etc/es-restart/es-api-key
sudo vi /etc/es-restart/es-api-key

# Cluster CA certificate
sudo cp http_ca.crt /etc/es-restart/

# Configuration
cd /opt/es-tools
sudo cp .env.example .env
sudo chown esadmin .env && sudo chmod 600 .env
sudo vi .env
```

Verify connectivity and configuration:

```bash
./es-rolling-restart.sh status
./es-rolling-restart.sh --dry-run
```

---

## Configuration

Configuration is read, in order of precedence, from:

1. Command-line options (`--force`, `--dry-run`)
2. Environment variables
3. The `.env` file next to the script, or the file given with `--env-file PATH`
4. Built-in defaults

The `.env` file contains plain `KEY=VALUE` lines. It is **parsed, never executed**,
unknown variables are rejected, and it must not be readable by group or others
(`chmod 600`).

### Connection

| Variable | Default | Description |
|----------|---------|-------------|
| `ES_URL` | `https://localhost:9200` | One or more cluster URLs, comma-separated. If one is unavailable (e.g. the node under maintenance), the next is tried. Configure at least two, or a load balancer. |
| `ES_CACERT` | `/etc/elasticsearch/certs/http_ca.crt` | CA certificate used to verify the cluster's TLS certificate |
| `INSECURE` | `0` | `1` disables TLS verification (`curl -k`). **Testing only.** |

### Credentials

| Variable | Description |
|----------|-------------|
| `ES_API_KEY_FILE` | **Recommended.** File containing only the API key |
| `ES_API_KEY` | API key inline (less secure) |
| `ES_USER` / `ES_PASS_FILE` / `ES_PASS` | Basic authentication, as an alternative to an API key |

The `*_FILE` variants take precedence. Secret files must not be readable by
others. Secrets are passed to `curl` through standard input, so they never
appear in the process list (`ps`), and they are removed from the environment
before any SSH command is executed.

The `*_FILE` variables integrate directly with secret delivery mechanisms such as
systemd credentials (`ES_API_KEY_FILE=%d/es-api-key` together with
`LoadCredentialEncrypted=`), Vault Agent templates or CI/CD secret files.

### SSH and service

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_USER` | current user | User for SSH connections to the nodes |
| `SSH_OPTS` | `-o BatchMode=yes -o ConnectTimeout=10` | Additional SSH options |
| `SSH_HOST_FROM` | `ip` | Node attribute used as the SSH target: `ip` or `name` |
| `SERVICE` | `elasticsearch` | systemd service name |
| `POST_START` | `1` | `post`: start the service if it is not running. `0`: only wait for it (requires the service to be enabled at boot). |
| `NODES` | *(all)* | `restart` only: space-separated list of node names to restart |

### Timeouts

All values are maximums in seconds; the script proceeds as soon as each condition is met.

| Variable | Default | Waits for |
|----------|---------|-----------|
| `WAIT_LEAVE_TIMEOUT` | `300` | A stopped node to leave the cluster |
| `WAIT_SSH_TIMEOUT` | `1800` | `post`: the host to accept SSH again (reboot after patching) |
| `WAIT_NODE_TIMEOUT` | `1800` | The node to rejoin the cluster |
| `WAIT_GREEN_TIMEOUT` | `3600` | The cluster to return to GREEN |
| `POLL` | `10` | Interval between checks |

Recovery time depends on the amount of data on the node, the write activity
while it was down and `indices.recovery.max_bytes_per_sec`. Measure it during
the first runs and adjust `WAIT_GREEN_TIMEOUT` with a safety margin.

### Example `.env`

```
ES_URL=https://es-master-01:9200,https://es-master-02:9200,https://es-master-03:9200
ES_API_KEY_FILE=/etc/es-restart/es-api-key
ES_CACERT=/etc/es-restart/http_ca.crt
SSH_USER=esadmin
WAIT_GREEN_TIMEOUT=5400
```

---

## Commands

```
es-rolling-restart.sh [options] [restart | pre <node> | post <node> | order | status]
```

| Command | Description |
|---------|-------------|
| `restart` | Full rolling restart of the cluster (default when no command is given) |
| `pre <node>` | Prepare a single node for maintenance and stop it |
| `post <node>` | Bring a node back after maintenance and wait for GREEN |
| `order` | Print the recommended maintenance order (`<node_name> <host>` per line) |
| `status` | Print cluster health, allocation setting, elected master and nodes |

| Option | Description |
|--------|-------------|
| `-f`, `--force`, `-y`, `--yes` | Skip the confirmation prompt of `restart` |
| `-n`, `--dry-run` | Print the planned actions without executing them |
| `-e`, `--env-file PATH` | Load configuration from `PATH` |
| `-h`, `--help` | Show the built-in help |

`<node>` is the **Elasticsearch node name** (as shown by `status` or
`GET _cat/nodes`), which may differ from the hostname.

Log messages are written to standard error; the output of `order` is written to
standard output so it can be consumed by other tools.

---

## Patching workflow (pre / post)

Use `pre` and `post` when another process (manual work, Ansible, Satellite, etc.)
patches and/or reboots the hosts.

```bash
./es-rolling-restart.sh order        # 1. get the order; process the elected master last

# 2. For each node, strictly one at a time:
./es-rolling-restart.sh pre es-data-01
#    ... patch the OS, reboot the host ...
./es-rolling-restart.sh post es-data-01
#    Only continue with the next node if 'post' exits with code 0.
```

### `pre <node>`

1. Refuses to start (exit code `3`) if the cluster is not GREEN or if shard
   allocation is already restricted, i.e. another maintenance is in progress or
   a previous one was not completed. This prevents two nodes from being taken
   down at the same time.
2. Checks over SSH whether the service is enabled at boot, and warns if it is not.
3. Warns if the node is the elected master.
4. Disables replica allocation, flushes, stops the service and waits for the
   node to leave the cluster.
5. Stores the node's host locally so `post` can reach it while the node is out
   of the cluster.

When `pre` finishes successfully, the host can be patched and rebooted.

### `post <node>`

1. Waits for the host to accept SSH connections (it may still be rebooting).
2. Starts the service if it is not running (`POST_START=1`).
3. Waits for the node to rejoin the cluster. If it is already back (e.g. started
   automatically after the reboot), this step is skipped.
4. Re-enables shard allocation and waits for the cluster to return to GREEN.

`pre` and `post` for the same node must be run **from the same administration
host**, since the node's host is stored locally between both phases
(`~/.local/state/es-rolling-restart/`).

### Ansible example

```yaml
- name: Patch Elasticsearch nodes
  hosts: elasticsearch            # inventory ordered according to "order"
  serial: 1                       # one node at a time, mandatory
  any_errors_fatal: true          # stop everything on the first failure
  tasks:
    - name: Take node out of service
      ansible.builtin.command: /opt/es-tools/es-rolling-restart.sh pre {{ es_node_name }}
      delegate_to: localhost

    - name: Apply OS updates
      ansible.builtin.dnf:
        name: "*"
        state: latest

    - name: Reboot
      ansible.builtin.reboot:

    - name: Bring node back and wait for GREEN
      ansible.builtin.command: /opt/es-tools/es-rolling-restart.sh post {{ es_node_name }}
      delegate_to: localhost
```

`es_node_name` is an inventory variable holding the Elasticsearch node name of
each host.

---

## Full rolling restart

To restart every node without any additional maintenance (e.g. to apply a
configuration change):

```bash
./es-rolling-restart.sh --dry-run    # review the plan
./es-rolling-restart.sh              # interactive: asks for confirmation
./es-rolling-restart.sh --force      # unattended (cron, CI, systemd timer)
```

Restart only some nodes:

```bash
NODES="es-data-01 es-data-02" ./es-rolling-restart.sh
```

Without a terminal (cron, CI) and without `--force`, the script aborts instead of
waiting for a confirmation.

### Example output

```
[INFO] Connecting to https://es-master-01:9200,... (authentication: API key)
[INFO] Cluster: prod-logs  Version: 9.2.1
[INFO] Current elected master: es-master-02
[INFO] Nodes to be restarted:
[INFO]   es-data-01: data/other
[INFO]   es-data-02: data/other
[INFO]   es-master-01: master-eligible
[INFO]   es-master-02: ELECTED MASTER (will be restarted last)
[INFO]   es-master-03: master-eligible
[WARN] Force mode enabled: proceeding without confirmation
[INFO] ========== [1/5] Node es-data-01 (10.10.0.21) — data/other ==========
[INFO] Setting shard allocation to: primaries
[INFO] Flushing indices
[INFO] Stopping elasticsearch on 10.10.0.21
[INFO] Node es-data-01 has left the cluster
[INFO] Starting elasticsearch on 10.10.0.21 (no-op if already running)
[INFO] Node es-data-01 has rejoined the cluster
[INFO] Setting shard allocation to: null
[INFO] Waiting for cluster health to return to GREEN...
[INFO] Cluster health is GREEN
...
[INFO] ========== [5/5] Node es-master-02 (10.10.0.12) — ELECTED MASTER ==========
...
[INFO] Rolling restart completed successfully (5 nodes).
```

---

## Exit codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | Continue |
| `1` | Error: timeout, SSH or API failure, cancelled by user | Investigate; see [Troubleshooting](#troubleshooting) |
| `2` | Invalid arguments or configuration, or confirmation required but no TTY | Fix the invocation or configuration |
| `3` | Precondition not met: cluster not GREEN, maintenance already in progress, unknown node | **Do not patch.** Check `status` |

---

## Troubleshooting

**Check the current state at any time:**

```bash
./es-rolling-restart.sh status
```

**`pre` fails with "Cluster health is 'yellow'".**
A node may still be recovering, or a previous maintenance was not completed.
Wait for GREEN, or complete the previous node with `post <node>`.

**`pre` fails with "Shard allocation is 'primaries'".**
A previous maintenance did not run `post`. Run `post <node>` for that node. If
the node is already back in the cluster, `post` only re-enables allocation and
waits for GREEN.

**The script stopped with an error after `pre` or during `restart`.**
Shard allocation may still be restricted. Once the node is back, run
`post <node>`, or re-enable allocation manually:

```
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": null } }
```

**Timeout waiting for GREEN.**
Recovery may be slow rather than stuck. Check progress with `GET _cat/recovery?active_only=true`
and `GET _cluster/allocation/explain`, then run `post <node>` again (it is safe
to repeat). Increase `WAIT_GREEN_TIMEOUT` if this happens regularly.

**`post` fails with "its host is unknown".**
`pre` was run from a different machine, or its state was removed. Wait for the
node to rejoin the cluster (start the service manually if needed) and run
`post <node>` again: the host is then resolved from the cluster.

**TLS errors when connecting.**
Check that `ES_CACERT` points to the cluster CA and that every hostname in
`ES_URL` is included in the node certificates.

**SSH errors.**
Verify `ssh esadmin@<host> true` works without a password prompt from the
administration host, and that the sudoers rule allows `systemctl stop/start`.

---

## Safety notes

- Never process two nodes in parallel. The script refuses `pre` while another
  maintenance is in progress, but the calling tool must also run strictly
  sequentially (`serial: 1` in Ansible).
- Always process the elected master last; use `order` to obtain the sequence.
- Run `--dry-run` and `status` before the first production run.
- Nodes above the disk low watermark recover slowly; free disk space before
  starting.
- Keep the API key scoped to this script, with an expiration date, and rotate it
  periodically.
