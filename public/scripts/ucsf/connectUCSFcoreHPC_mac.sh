#!/bin/bash
#
# CoreHPC Neurodesktop launcher -- macOS / Linux / WSL version.
# Run it from Terminal:  bash connectUCSFcoreHPC_mac.sh
# On Windows, run connectUCSFcoreHPC_win.sh from Git Bash instead: Git Bash cannot
# share one SSH connection between commands, which this version relies on.

# jiazheng.zhou@ucsf.edu
# sep 2026
#
COREHPC_SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
COREHPC_SCRIPT_NAME="${COREHPC_SCRIPT_NAME:-connectUCSFcoreHPC_mac.sh}"

random_tunnel_port() {
    # macOS does not ship `shuf` by default.
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-65000 -n 1
        return
    fi

    echo $((10000 + RANDOM % 55001))
}

random_notebook_token() {
    # A URL-safe token the user authenticates with. Prefer a cryptographically
    # strong source; fall back to combining RANDOM if openssl is unavailable.
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24 2>/dev/null && return
    fi
    if [ -r /dev/urandom ] && command -v hexdump >/dev/null 2>&1; then
        hexdump -n 24 -e '24/1 "%02x"' /dev/urandom 2>/dev/null && return
    fi
    printf '%s%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
}

normalize_memory_request() {
    local MEM="$1"

    MEM=${MEM//[[:space:]]/}
    MEM=$(printf '%s' "$MEM" | tr '[:lower:]' '[:upper:]')
    if [[ "$MEM" =~ ^[0-9]+$ ]]; then
        MEM="${MEM}G"
    fi
    printf '%s\n' "$MEM"
}

corehpc_walltime_is_valid() {
    local WALLTIME_VALUE="$1"
    local DAYS=0 HOURS=0 MINUTES=0 SECONDS=0 TOTAL_SECONDS

    if [[ "$WALLTIME_VALUE" =~ ^([0-9]+)-([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
        DAYS=$((10#${BASH_REMATCH[1]}))
        HOURS=$((10#${BASH_REMATCH[2]}))
        MINUTES=$((10#${BASH_REMATCH[3]}))
        SECONDS=$((10#${BASH_REMATCH[4]}))
        [ "$HOURS" -lt 24 ] || return 1
    elif [[ "$WALLTIME_VALUE" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
        HOURS=$((10#${BASH_REMATCH[1]}))
        MINUTES=$((10#${BASH_REMATCH[2]}))
        SECONDS=$((10#${BASH_REMATCH[3]}))
    else
        return 1
    fi

    [ "$MINUTES" -lt 60 ] && [ "$SECONDS" -lt 60 ] || return 1
    TOTAL_SECONDS=$((DAYS * 86400 + HOURS * 3600 + MINUTES * 60 + SECONDS))
    [ "$TOTAL_SECONDS" -gt 0 ] && [ "$TOTAL_SECONDS" -le 345600 ]
}

port_is_free_local() {
    local PORT="$1"

    if [ -z "$PORT" ]; then
        return 1
    fi

    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$PORT )" 2>/dev/null | awk 'NR>1 {found=1} END {exit(found ? 0 : 1)}'; then
            return 1
        fi
        return 0
    fi

    if command -v netstat >/dev/null 2>&1; then
        if netstat -an 2>/dev/null | grep -Eq "[\\.:]${PORT}[[:space:]].*LISTEN"; then
            return 1
        fi
        return 0
    fi

    return 0
}

port_is_free_remote() {
    local SSH_SOCKET="$1"
    local SSH_TARGET="$2"
    local PORT="$3"

    ssh -S "$SSH_SOCKET" -q "$SSH_TARGET" "bash -s -- \"$PORT\"" <<'EOF'
port="$1"

if [ -z "$port" ]; then
    exit 1
fi

if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
        exit 1
    fi
    exit 0
fi

if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR>1 {found=1} END {exit(found ? 0 : 1)}'; then
        exit 1
    fi
    exit 0
fi

if command -v netstat >/dev/null 2>&1; then
    if netstat -an 2>/dev/null | grep -Eq "[\\.:]${port}[[:space:]].*LISTEN"; then
        exit 1
    fi
    exit 0
fi

exit 0
EOF
}

choose_shared_tunnel_port() {
    local SSH_SOCKET="$1"
    local SSH_TARGET="$2"
    local MAX_ATTEMPTS="${3:-80}"
    local ATTEMPT=1
    local CANDIDATE_PORT

    while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
        CANDIDATE_PORT=$(random_tunnel_port)
        if [[ ! "$CANDIDATE_PORT" =~ ^[0-9]+$ ]]; then
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi

        if ! port_is_free_local "$CANDIDATE_PORT"; then
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi

        if ! port_is_free_remote "$SSH_SOCKET" "$SSH_TARGET" "$CANDIDATE_PORT"; then
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi

        echo "$CANDIDATE_PORT"
        return 0
    done

    return 1
}

choose_attach_tunnel_port() {
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local PREFERRED_PORT="$3"

    if [[ "$PREFERRED_PORT" =~ ^[0-9]+$ ]] &&
       port_is_free_local "$PREFERRED_PORT" &&
       port_is_free_remote "$SSH_SOCKET" "$LOGIN_NODE" "$PREFERRED_PORT"; then
        echo "$PREFERRED_PORT"
        return 0
    fi

    choose_shared_tunnel_port "$SSH_SOCKET" "$LOGIN_NODE"
}

ssh_config_has_host_alias() {
    local SSH_CONFIG_FILE="$1"
    local TARGET_ALIAS="$2"

    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        return 1
    fi

    awk -v target="$TARGET_ALIAS" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
            line = $0
            sub(/^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/, "", line)
            split(line, host_patterns, /[[:space:]]+/)
            for (i in host_patterns) {
                if (tolower(host_patterns[i]) == tolower(target)) {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$SSH_CONFIG_FILE"
}

ensure_corehpc_ssh_config() {
    local LOGIN_ALIAS="$1"
    local BASTION_ALIAS="$2"
    local BASTION_HOST="$3"
    local SSH_DIR="${HOME}/.ssh"
    local SSH_CONFIG_FILE="${SSH_DIR}/config"
    local USER_CHOICE
    local COREHPC_USER_NAME
    local COREHPC_LOGIN_HOST_NAME="${COREHPC_LOGIN_HOST:-}"
    local HAS_LOGIN_ALIAS=0
    local HAS_BASTION_ALIAS=0

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR" 2>/dev/null || true

    ssh_config_has_host_alias "$SSH_CONFIG_FILE" "$LOGIN_ALIAS" && HAS_LOGIN_ALIAS=1
    ssh_config_has_host_alias "$SSH_CONFIG_FILE" "$BASTION_ALIAS" && HAS_BASTION_ALIAS=1
    if [ "$HAS_LOGIN_ALIAS" -eq 1 ] && [ "$HAS_BASTION_ALIAS" -eq 1 ]; then
        return 0
    fi

    echo "CoreHPC needs an SSH jump through ${BASTION_HOST} to a login or session node."
    echo "One or both SSH aliases ('${BASTION_ALIAS}', '${LOGIN_ALIAS}') are missing from ${SSH_CONFIG_FILE}."
    echo -n "Add the missing CoreHPC SSH config entries now? [Y/n] "
    read -r USER_CHOICE

    if [[ "$USER_CHOICE" =~ ^([nN][oO]|[nN])$ ]]; then
        echo "Skipping SSH config update."
        return 1
    fi

    echo -n "UCSF CoreHPC username [${COREHPC_USER:-$USER}]: "
    read -r COREHPC_USER_NAME
    COREHPC_USER_NAME=${COREHPC_USER_NAME:-${COREHPC_USER:-$USER}}
    if [[ ! "$COREHPC_USER_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        echo "The CoreHPC username contains unsupported characters."
        return 1
    fi

    if [ "$HAS_LOGIN_ALIAS" -eq 0 ] && [ -z "$COREHPC_LOGIN_HOST_NAME" ]; then
        echo -n "CoreHPC login/session hostname from your welcome email: "
        read -r COREHPC_LOGIN_HOST_NAME
        if [ -z "$COREHPC_LOGIN_HOST_NAME" ]; then
            echo "A login or session node hostname is required. The bastion does not run Slurm jobs."
            return 1
        fi
    fi
    if [ "$HAS_LOGIN_ALIAS" -eq 0 ] && [[ ! "$COREHPC_LOGIN_HOST_NAME" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        echo "The CoreHPC login/session hostname contains unsupported characters."
        return 1
    fi

    if [ -f "$SSH_CONFIG_FILE" ] && [ -s "$SSH_CONFIG_FILE" ]; then
        printf "\n" >> "$SSH_CONFIG_FILE"
    fi

    if [ "$HAS_BASTION_ALIAS" -eq 0 ]; then
        cat >> "$SSH_CONFIG_FILE" <<EOF
Host ${BASTION_ALIAS}
    HostName ${BASTION_HOST}
    User ${COREHPC_USER_NAME}
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
    fi

    if [ "$HAS_LOGIN_ALIAS" -eq 0 ]; then
        cat >> "$SSH_CONFIG_FILE" <<EOF

Host ${LOGIN_ALIAS}
    HostName ${COREHPC_LOGIN_HOST_NAME}
    User ${COREHPC_USER_NAME}
    ProxyJump ${BASTION_ALIAS}
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
    fi

    chmod 600 "$SSH_CONFIG_FILE" 2>/dev/null || true
    echo "Added the missing CoreHPC SSH entries to ${SSH_CONFIG_FILE}."
    return 0
}

hold_neurodesk_tunnel() {
    # Hold the tunnel through the configured bastion and login node to the
    # compute node, landing on the notebook's localhost port. It runs in the
    # foreground; Ctrl-C or a dropped network only tears down the tunnel, not
    # the batch job.
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local NODE_NAME="$3"
    local TUNNEL_PORT="$4"
    local NOTEBOOK_PORT="$5"

    # Pre-check the local end so a busy port gives a clear message instead of a
    # raw SSH "bind: Address already in use" error from the -L forward.
    if ! port_is_free_local "$TUNNEL_PORT"; then
        echo "Local port ${TUNNEL_PORT} is already in use on this machine, so the tunnel cannot be opened."
        echo "Free whatever is listening on ${TUNNEL_PORT} (e.g. an old tunnel), then re-run ${COREHPC_SCRIPT_NAME} to reattach."
        echo "The Slurm job is unaffected and keeps running on ${NODE_NAME}."
        return 1
    fi

    if ! port_is_free_remote "$SSH_SOCKET" "$LOGIN_NODE" "$TUNNEL_PORT"; then
        echo "Login-node port ${TUNNEL_PORT} is already in use, so the tunnel cannot be opened."
        echo "Re-run ${COREHPC_SCRIPT_NAME} to pick a fresh attach port."
        echo "The Slurm job is unaffected and keeps running on ${NODE_NAME}."
        return 1
    fi

    ssh -S "$SSH_SOCKET" -o ExitOnForwardFailure=yes -t \
        -L "${TUNNEL_PORT}:localhost:${TUNNEL_PORT}" "$LOGIN_NODE" \
        "ssh -o ExitOnForwardFailure=yes -N -L ${TUNNEL_PORT}:localhost:${NOTEBOOK_PORT} ${NODE_NAME}"
}

report_neurodesk_job_diagnostics() {
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local JOB_ID="$3"
    local TUNNEL_STATUS="$4"

    echo
    echo "Tunnel exited with status ${TUNNEL_STATUS}; checking Slurm job state before cleanup prompt..."
    if ! ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "bash -s -- \"$JOB_ID\"" <<'EOF'
job_id="$1"
log_file="${HOME}/.neurodesk_job_${job_id}.log"
failure_pattern='OUT_OF_MEMORY|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|PREEMPTED|oom|oom_kill|out.of.memory|Killed|error:'

echo "Slurm queue state:"
queue_state=$(squeue -j "$job_id" -h -o '  job=%i state=%T reason=%r node=%N time-left=%L' 2>/dev/null || true)
if [ -n "$queue_state" ]; then
    printf '%s\n' "$queue_state"
else
    echo "  not in squeue (it may have completed, failed, or been cancelled)"
fi

if command -v sacct >/dev/null 2>&1; then
    echo "Slurm accounting state:"
    accounting_state=$(sacct -j "$job_id" --format=JobID,State,ExitCode,Elapsed,MaxRSS -P -n 2>/dev/null || true)
    if [ -n "$accounting_state" ]; then
        printf '%s\n' "$accounting_state" |
            awk -F'|' '{printf "  job=%s state=%s exit=%s elapsed=%s maxrss=%s\n", $1, $2, $3, $4, $5}'
        if printf '%s\n' "$accounting_state" | grep -Eiq "$failure_pattern"; then
            echo "  Detected failure state in Slurm accounting."
        fi
    else
        echo "  sacct has no record yet (accounting can lag briefly)"
    fi
else
    echo "Slurm accounting state: sacct is not available"
fi

if [ -r "$log_file" ]; then
    if grep -Eiq "$failure_pattern" "$log_file"; then
        echo "Recent warning/error lines from ${log_file}:"
        grep -Ein "$failure_pattern" "$log_file" | tail -20 | sed 's/^/  /'
    fi
    echo "Last 60 lines from ${log_file}:"
    tail -60 "$log_file" | sed 's/^/  /'
else
    echo "Job log is not readable yet: ${log_file}"
fi
EOF
    then
        echo "Could not query Slurm diagnostics through $LOGIN_NODE."
        echo "Try manually: ssh $LOGIN_NODE 'sacct -j $JOB_ID; tail -60 ~/.neurodesk_job_${JOB_ID}.log'"
    fi
}

attach_neurodesk_job() {
    # Wait for a (possibly queued) job to start, recover the node + notebook
    # port it recorded in its per-job state file, then hold the tunnel. Used for
    # fresh launches and for reconnecting/attaching to existing jobs alike.
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local JOB_ID="$3"
    local NODE_NAME="" WAITED=0
    local MAX_WAIT="${NEURODESKTOP_START_TIMEOUT:-600}"
    local POLL_INTERVAL="${COREHPC_POLL_INTERVAL:-5}"
    local LAST_HEARTBEAT=0
    local INFO STATE REASON STARTTIME LAST_REASON=""
    local TUNNEL_PORT
    local TUNNEL_STATUS

    if [[ ! "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
        POLL_INTERVAL=5
    fi

    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        # One query for everything: state | node | pending-reason | est-start.
        INFO=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "squeue -j $JOB_ID -h -o '%t|%N|%r|%S' 2>/dev/null")
        if [ -z "$INFO" ]; then
            # Job has left the queue entirely (started+finished, failed, cancelled).
            echo "Job $JOB_ID is no longer in the queue (it may have failed or been cancelled)."
            echo "Check its log: ssh $LOGIN_NODE cat ~/.neurodesk_job_${JOB_ID}.log"
            return 1
        fi
        IFS='|' read -r STATE NODE_NAME REASON STARTTIME <<< "$INFO"
        if [ "$STATE" = "R" ] && [ -n "$NODE_NAME" ]; then
            break
        fi

        # Surface why it is still waiting. Print whenever the reason changes, and
        # otherwise a heartbeat every ~60s, so the user is never left guessing.
        REASON=${REASON:-unknown}
        if [ "$REASON" != "$LAST_REASON" ]; then
            echo "  [${WAITED}s] state=${STATE} reason=${REASON}${STARTTIME:+ est-start=${STARTTIME}}"
            case "$REASON" in
                Resources|Priority|None|null)
                    echo "        (normal queue wait: the partition is busy and the job is waiting for a slot)" ;;
                ReqNodeNotAvail*|*Reservation*)
                    echo "        ('$PARTITION' nodes are unavailable right now -- often an upcoming maintenance"
                    echo "         reservation your walltime overlaps, or the owner nodes are reserved/busy/down."
                    echo "         Try a shorter --time or check 'ssh $LOGIN_NODE scontrol show reservation'.)" ;;
                *PartitionTimeLimit*|*PartitionNodeLimit*|*PartitionConfig*)
                    echo "        (the request may exceed what '$PARTITION' allows -- e.g. walltime, mem, or GPUs; this can wait indefinitely)" ;;
                *QOS*|*Assoc*|*Grp*)
                    echo "        (a usage/QOS limit is holding it -- you may already have another job running)" ;;
            esac
            LAST_REASON="$REASON"
            LAST_HEARTBEAT="$WAITED"
        elif [ $((WAITED - LAST_HEARTBEAT)) -ge 60 ]; then
            echo "  [${WAITED}s] still waiting: ${REASON}${STARTTIME:+ (est-start ${STARTTIME})}"
            LAST_HEARTBEAT="$WAITED"
        fi

        sleep "$POLL_INTERVAL"
        WAITED=$((WAITED + POLL_INTERVAL))
    done

    if [ "$STATE" != "R" ] || [ -z "$NODE_NAME" ]; then
        echo "Job $JOB_ID has not started within ${MAX_WAIT}s; it is still queued (reason: ${LAST_REASON:-unknown})."
        echo "Re-run ${COREHPC_SCRIPT_NAME} later to attach once it is running,"
        echo "or cancel it with: ssh $LOGIN_NODE scancel $JOB_ID"
        return 0
    fi

    # The job writes its per-job state file at startup; poll briefly to avoid a
    # race where it is "R" but hasn't recorded its port yet. The path is resolved
    # on the remote (escaped $HOME) rather than relying on tilde expansion.
    local STATE_REL=".neurodesk_session_${JOB_ID}.env"
    local STATE_CONTENT SAVED_PORT SAVED_NODE SAVED_TOKEN PORT_TRIES=0
    while [ "$PORT_TRIES" -lt 8 ]; do
        STATE_CONTENT=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "cat \"\$HOME/${STATE_REL}\" 2>/dev/null")
        SAVED_PORT=$(printf '%s\n' "$STATE_CONTENT" | awk -F= '$1=="NEURODESK_PORT"{print $2}')
        SAVED_NODE=$(printf '%s\n' "$STATE_CONTENT" | awk -F= '$1=="NEURODESK_NODE"{print $2}')
        SAVED_TOKEN=$(printf '%s\n' "$STATE_CONTENT" | awk -F= '$1=="NEURODESK_TOKEN"{print $2}')
        if [[ "$SAVED_PORT" =~ ^[0-9]+$ ]]; then
            break
        fi
        sleep 2
        PORT_TRIES=$((PORT_TRIES + 1))
    done
    [ -n "$SAVED_NODE" ] && NODE_NAME="$SAVED_NODE"

    if [[ ! "$SAVED_PORT" =~ ^[0-9]+$ ]]; then
        echo "Job $JOB_ID is running on $NODE_NAME but its saved notebook port could not be read."
        echo "Wait a few seconds and re-run ${COREHPC_SCRIPT_NAME} to attach,"
        echo "or inspect: ssh $LOGIN_NODE cat ~/${STATE_REL}"
        return 1
    fi

    TUNNEL_PORT=$(choose_attach_tunnel_port "$SSH_SOCKET" "$LOGIN_NODE" "$SAVED_PORT")
    if [[ ! "$TUNNEL_PORT" =~ ^[0-9]+$ ]]; then
        echo "Failed to find a free local/login tunnel port for job $JOB_ID."
        echo "The notebook is still listening on ${NODE_NAME}:${SAVED_PORT} inside the Slurm allocation."
        prompt_keep_or_cancel_on_exit "$SSH_SOCKET" "$LOGIN_NODE" "$JOB_ID"
        return
    fi

    local NOTEBOOK_URL="http://127.0.0.1:${TUNNEL_PORT}"
    if [ -n "$SAVED_TOKEN" ]; then
        NOTEBOOK_URL="${NOTEBOOK_URL}/lab?token=${SAVED_TOKEN}"
    fi

    # Report remaining walltime so a reconnecting user knows how long the session
    # has left before Slurm reclaims it. %L is TimeLeft, %l is the TimeLimit.
    local TIME_INFO TIME_LEFT TIME_LIMIT
    TIME_INFO=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "squeue -j $JOB_ID -h -o '%L|%l' 2>/dev/null")
    IFS='|' read -r TIME_LEFT TIME_LIMIT <<< "$TIME_INFO"

    echo "Job $JOB_ID is running on $NODE_NAME."
    if [ -n "$TIME_LEFT" ] && [ "$TIME_LEFT" != "INVALID" ]; then
        echo "Walltime remaining: ${TIME_LEFT}${TIME_LIMIT:+ of ${TIME_LIMIT}} (D-HH:MM:SS)."
    fi
    echo "Container log: ssh $LOGIN_NODE tail -f ~/.neurodesk_job_${JOB_ID}.log"
    echo "Tunnel mapping: local ${TUNNEL_PORT} -> ${LOGIN_NODE} ${TUNNEL_PORT} -> ${NODE_NAME} ${SAVED_PORT}"
    echo "Notebook will be available at ${NOTEBOOK_URL} (allow ~30s for startup)."
    if [ -z "$SAVED_TOKEN" ]; then
        echo "  (No token recorded for this job; if Jupyter asks for one, find it with:"
        echo "   ssh $LOGIN_NODE grep -m1 token= ~/.neurodesk_job_${JOB_ID}.log )"
    fi
    echo "Press Ctrl-C to disconnect; you'll then be asked whether to cancel or keep the job."
    # Hold the tunnel in the foreground. A bare 'trap : INT' keeps this script
    # alive when Ctrl-C tears down the tunnel (the child ssh still gets the default
    # SIGINT and exits), so control returns here and we can prompt about the job.
    trap ':' INT
    hold_neurodesk_tunnel "$SSH_SOCKET" "$LOGIN_NODE" "$NODE_NAME" "$TUNNEL_PORT" "$SAVED_PORT"
    TUNNEL_STATUS=$?
    trap - INT
    if [ "$TUNNEL_STATUS" -ne 0 ]; then
        report_neurodesk_job_diagnostics "$SSH_SOCKET" "$LOGIN_NODE" "$JOB_ID" "$TUNNEL_STATUS"
    fi
    prompt_keep_or_cancel_on_exit "$SSH_SOCKET" "$LOGIN_NODE" "$JOB_ID"
}

cancel_neurodesk_job() {
    # Ask whether to cancel an existing job. Returns 0 if it was cancelled (the
    # caller may then launch a fresh session), 1 if the user declined or the
    # cancel failed (the caller should abort).
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local JOB_ID="$3"
    local confirm

    echo -n "Cancel job $JOB_ID now so you can start a fresh session? [y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "Leaving job $JOB_ID in place. Re-run ${COREHPC_SCRIPT_NAME} to attach to it."
        return 1
    fi

    if ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "scancel $JOB_ID"; then
        echo "Cancelled job $JOB_ID."
        return 0
    fi
    echo "Failed to cancel job $JOB_ID. Cancel it manually: ssh $LOGIN_NODE scancel $JOB_ID"
    return 1
}

prompt_keep_or_cancel_on_exit() {
    # Called once the foreground tunnel has dropped (Ctrl-C or lost link). For a
    # batch job the Slurm allocation is still running, so ask whether to cancel it
    # now or leave it for a later reconnect. Defaults to keeping it (safer).
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local JOB_ID="$3"
    local choice

    # If the job already left the queue (walltime hit, cancelled elsewhere), there
    # is nothing to ask about.
    if ! ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "squeue -j $JOB_ID -h -o '%t' 2>/dev/null" | grep -q .; then
        echo "Job $JOB_ID is no longer running; nothing to clean up."
        return 0
    fi

    echo
    echo "Tunnel closed. Job $JOB_ID is still running on CoreHPC."
    echo -n "Cancel the session now? (No keeps it running to reconnect later) [y/N] "
    read -r choice
    if [[ ! "$choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "Leaving job $JOB_ID running. Re-run ${COREHPC_SCRIPT_NAME} to reattach."
        return 0
    fi

    if ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "scancel $JOB_ID"; then
        echo "Cancelled job $JOB_ID."
    else
        echo "Failed to cancel job $JOB_ID. Cancel it manually: ssh $LOGIN_NODE scancel $JOB_ID"
    fi
}

ensure_corehpc_neurodesktop_image() {
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local LAB_ROOT="$3"
    local VERSION="$4"
    local SLURM_ACCOUNT_VALUE="$5"
    local NEURODESK_DIR="${LAB_ROOT}/neurodesk"
    local VERSION_IMAGE="${NEURODESK_DIR}/neurodesktop_${VERSION}.sif"
    local LATEST_IMAGE="${NEURODESK_DIR}/neurodesktop_latest.sif"
    local CURRENT_TARGET=""
    local UPDATE_CHOICE
    local UPDATE_OUTPUT UPDATE_STATUS UPDATE_PID UPDATE_STATE UPDATE_LOG

    if ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "test -s '$LATEST_IMAGE'"; then
        CURRENT_TARGET=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "readlink '$LATEST_IMAGE' 2>/dev/null || printf '%s' '$LATEST_IMAGE'")
        if [ "${CURRENT_TARGET##*/}" = "neurodesktop_${VERSION}.sif" ]; then
            echo "Neurodesktop ${VERSION} is already available."
            return 0
        fi

        echo "Current Neurodesktop image: ${CURRENT_TARGET##*/}"
        echo -n "Upgrade the shared image to Neurodesktop ${VERSION}? [y/N] "
        read -r UPDATE_CHOICE
        if [[ ! "$UPDATE_CHOICE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            echo "Keeping the current shared Neurodesktop image."
            return 0
        fi
    else
        echo "No shared Neurodesktop image was found. Neurodesktop ${VERSION} will be downloaded."
    fi

    # The pull must run on the login node: compute nodes resolve the site proxy
    # (chpc-proxy-vm1:3128) but have no route to it, so ghcr.io is unreachable there.
    if ! ssh -S "$SSH_SOCKET" "$LOGIN_NODE" "cat > ~/.neurodesk_update.sh && chmod +x ~/.neurodesk_update.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
umask 002

: "${COREHPC_LAB_ROOT:?COREHPC_LAB_ROOT is not set}"
: "${NEURODESKTOP_VERSION:?NEURODESKTOP_VERSION is not set}"

neurodesk_dir="${COREHPC_LAB_ROOT}/neurodesk"
image="${neurodesk_dir}/neurodesktop_${NEURODESKTOP_VERSION}.sif"
latest="${neurodesk_dir}/neurodesktop_latest.sif"
tmp="${neurodesk_dir}/.neurodesktop_${NEURODESKTOP_VERSION}.$$.sif"
link_tmp="${latest}.$$.tmp"

# Keep the multi-GB layer cache off the (small) home quota.
export APPTAINER_TMPDIR="${neurodesk_dir}/apptainer_temp/${USER}"
export APPTAINER_CACHEDIR="${neurodesk_dir}/apptainer_cache/${USER}"

mkdir -p "${neurodesk_dir}" "${APPTAINER_TMPDIR}" "${APPTAINER_CACHEDIR}"
trap 'rm -f "${tmp}" "${link_tmp}"' EXIT
rm -f "${tmp}" "${link_tmp}"

if [ ! -s "${image}" ]; then
    apptainer pull "${tmp}" "docker://ghcr.io/neurodesk/neurodesktop:${NEURODESKTOP_VERSION}"
    test -s "${tmp}"
    mv -f "${tmp}" "${image}"
fi

ln -s "${image}" "${link_tmp}"
mv -f "${link_tmp}" "${latest}"
test -s "${latest}"
echo "NEURODESK_UPDATE_OK"
EOF
    then
        echo "Failed to upload the Neurodesktop image update script."
        return 1
    fi

    UPDATE_LOG="\$HOME/.neurodesk_update.log"
    UPDATE_OUTPUT=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" \
        "rm -f ${UPDATE_LOG} ${UPDATE_LOG}.done; \
         setsid nohup env COREHPC_LAB_ROOT='${LAB_ROOT}' NEURODESKTOP_VERSION='${VERSION}' \
           bash -c '~/.neurodesk_update.sh; echo \$? > ${UPDATE_LOG}.done' \
           > ${UPDATE_LOG} 2>&1 < /dev/null & echo \$!")
    UPDATE_STATUS=$?
    UPDATE_PID=${UPDATE_OUTPUT//[[:space:]]/}
    if [ "$UPDATE_STATUS" -ne 0 ] || [[ ! "$UPDATE_PID" =~ ^[0-9]+$ ]]; then
        echo "Failed to start the Neurodesktop image download: ${UPDATE_OUTPUT}"
        return 1
    fi

    echo "Downloading Neurodesktop ${VERSION} on ${LOGIN_NODE} (pid ${UPDATE_PID}); this takes a while."
    while :; do
        # One round trip per poll: report completion, or else the size so far.
        # Note: the path must stay double-quoted so the *remote* shell expands $USER.
        UPDATE_STATE=$(ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" \
            "if test -f \$HOME/.neurodesk_update.log.done; then echo NEURODESK_UPDATE_DONE; \
             else du -sh \"${NEURODESK_DIR}/apptainer_cache/\$USER\" 2>/dev/null | cut -f1; fi")
        [ "$UPDATE_STATE" = "NEURODESK_UPDATE_DONE" ] && break
        echo "  downloaded so far: ${UPDATE_STATE:-0}"
        sleep 20
    done

    if ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" \
        "test -s '$VERSION_IMAGE' && [ \"\$(readlink '$LATEST_IMAGE')\" = '$VERSION_IMAGE' ]"; then
        echo "Neurodesktop ${VERSION} is ready at ${LATEST_IMAGE}."
        return 0
    fi

    echo "The image download did not create ${LATEST_IMAGE}."
    echo "Inspect it with: ssh ${LOGIN_NODE} 'tail -100 ~/.neurodesk_update.log'"
    return 1
}

corehpc_preflight_report() {
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local LAB_ROOT="$3"

    ssh -S "$SSH_SOCKET" -q "$LOGIN_NODE" "bash -s -- '$LAB_ROOT'" <<'EOF'
missing_tools=""
for tool in squeue scontrol sbatch apptainer; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools="${missing_tools} ${tool}"
done
echo "MISSING_TOOLS=${missing_tools# }"

missing_partitions=""
for partition in cpu gpu; do
    scontrol show partition "$partition" >/dev/null 2>&1 || missing_partitions="${missing_partitions} ${partition}"
done
echo "MISSING_PARTITIONS=${missing_partitions# }"

if [ -d "$1" ]; then
    echo "LAB_ROOT=ok"
else
    echo "LAB_ROOT=missing"
fi
echo "PREFLIGHT=done"
EOF
}

run_corehpc_preflight() {
    # Every check runs in a single remote call, and the message names exactly
    # what is missing.
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"
    local LAB_ROOT="$3"
    local PREFLIGHT MISSING_TOOLS MISSING_PARTITIONS

    PREFLIGHT=$(corehpc_preflight_report "$SSH_SOCKET" "$LOGIN_NODE" "$LAB_ROOT")
    if ! printf '%s\n' "$PREFLIGHT" | grep -qx 'PREFLIGHT=done'; then
        echo "CoreHPC preflight could not run on ${LOGIN_NODE}."
        return 1
    fi

    MISSING_TOOLS=$(printf '%s\n' "$PREFLIGHT" | awk -F= '$1=="MISSING_TOOLS"{print $2}')
    if [ -n "$MISSING_TOOLS" ]; then
        echo "CoreHPC preflight failed: not available on ${LOGIN_NODE}: ${MISSING_TOOLS}"
        return 1
    fi
    MISSING_PARTITIONS=$(printf '%s\n' "$PREFLIGHT" | awk -F= '$1=="MISSING_PARTITIONS"{print $2}')
    if [ -n "$MISSING_PARTITIONS" ]; then
        echo "CoreHPC preflight failed: Slurm partition unavailable: ${MISSING_PARTITIONS}"
        return 1
    fi
    if ! printf '%s\n' "$PREFLIGHT" | grep -qx 'LAB_ROOT=ok'; then
        echo "CoreHPC lab storage is not visible at ${LAB_ROOT}."
        echo "Confirm that FAC storage is mounted for your account before starting a job."
        return 1
    fi
}

close_corehpc_master() {
    local SSH_SOCKET="$1"
    local LOGIN_NODE="$2"

    [ -S "$SSH_SOCKET" ] || return 0
    # The master removes its own socket on exit; only a stale one is left behind.
    ssh -S "$SSH_SOCKET" -O exit "$LOGIN_NODE" >/dev/null 2>&1 || rm -f "$SSH_SOCKET"
}

function connectUCSFcoreHPC() {
    local LOGIN_NODE="${COREHPC_SSH_ALIAS:-corehpc}"
    local BASTION_ALIAS="${COREHPC_BASTION_ALIAS:-corehpc-bastion}"
    local BASTION_HOST="chpc-ucsf-bastion-vm1.corehpc.ucsf.edu"
    local COREHPC_LAB_ROOT="${COREHPC_LAB_ROOT:-}"
    if [ -z "$COREHPC_LAB_ROOT" ]; then
        echo 'Set COREHPC_LAB_ROOT to your lab storage directory before running this script.'
        echo 'Example: export COREHPC_LAB_ROOT="/mnt/fac/YOUR_LAB/YOUR_DIRECTORY"'
        return 1
    fi
    local NEURODESKTOP_VERSION="${NEURODESKTOP_VERSION:-2026-08-11}"
    local JOB_NAME="neurodesktop"
    local CTRL_SOCKET
    CTRL_SOCKET="${HOME}/.ssh/corehpc_ctrl_$(date +%s)_${RANDOM}"
    local NOTEBOOK_PORT
    local PARTITION MEM CPUS WALLTIME GPU SLURM_ACCOUNT

    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            echo "This is the macOS/Linux version of the CoreHPC connect script."
            echo "Git Bash on Windows cannot share one SSH connection between commands,"
            echo "so every step here would fail. Run connectUCSFcoreHPC_win.sh instead."
            return 1 ;;
    esac

    if [[ ! "$LOGIN_NODE" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "$BASTION_ALIAS" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "CoreHPC SSH aliases may contain only letters, numbers, dots, underscores, and hyphens."
        return 1
    fi
    if [[ ! "$COREHPC_LAB_ROOT" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
        echo "COREHPC_LAB_ROOT contains unsupported characters: ${COREHPC_LAB_ROOT}"
        return 1
    fi
    if [[ ! "$NEURODESKTOP_VERSION" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "NEURODESKTOP_VERSION contains unsupported characters: ${NEURODESKTOP_VERSION}"
        return 1
    fi

    echo "CoreHPC requires the UCSF network or UCSF VPN when off campus."
    if ! ensure_corehpc_ssh_config "$LOGIN_NODE" "$BASTION_ALIAS" "$BASTION_HOST"; then
        echo "Please add a valid SSH entry for '${LOGIN_NODE}' and run the script again."
        return 1
    fi

    # Start master connection
    # -M: master mode, -f: background, -N: no command, -S: socket path
    # ControlPersist is a backstop: if the script is killed in a way that skips
    # the trap below, the master still exits by itself once idle that long. Any
    # later call simply opens a normal connection if the master is already gone.
    if ! ssh -M -f -N -S "$CTRL_SOCKET" -o ControlPersist=30m "$LOGIN_NODE"; then
        echo "Authentication failed. Check the UCSF VPN, bastion access, login/session hostname, and SSH credentials."
        return 1
    fi
    # Close the master connection on return, and on Ctrl-C or kill (EXIT) --
    # otherwise an interrupted run leaves a background ssh behind.
    trap "close_corehpc_master $(printf '%q' "$CTRL_SOCKET") $(printf '%q' "$LOGIN_NODE"); trap - EXIT RETURN" EXIT RETURN

    if ! run_corehpc_preflight "$CTRL_SOCKET" "$LOGIN_NODE" "$COREHPC_LAB_ROOT"; then
        return 1
    fi

    # --- 1. ENFORCE A SINGLE NEURODESKTOP SESSION ---
    # Only one neurodesktop session is supported at a time: concurrent sessions
    # would share the same container home and Slurm staging dirs and clash. If a
    # running (R) or pending (PD) job already exists, we reconnect/attach to it
    # and never submit a second one. Match on --name so we don't touch unrelated
    # compute jobs.
    local EXISTING_JOBS RUNNING_JOB PENDING_JOB reuse waitq
    EXISTING_JOBS=$(ssh -S "$CTRL_SOCKET" -q "$LOGIN_NODE" "squeue -u \$USER --name=$JOB_NAME -h -t R,PD -o '%i %t'")
    RUNNING_JOB=$(printf '%s\n' "$EXISTING_JOBS" | awk '$2=="R"{print $1; exit}')
    PENDING_JOB=$(printf '%s\n' "$EXISTING_JOBS" | awk '$2=="PD"{print $1; exit}')

    if [ -n "$RUNNING_JOB" ]; then
        echo "A $JOB_NAME session is already running (Job $RUNNING_JOB)."
        echo "Only one session is supported at a time."
        echo -n "Reconnect to it? [Y/n] "
        read -r reuse
        # Default to Yes: rebuild the tunnel from scratch (works even after the
        # original terminal is gone) by reading the job's per-job state file.
        if [[ ! "$reuse" =~ ^([nN][oO]|[nN])$ ]]; then
            attach_neurodesk_job "$CTRL_SOCKET" "$LOGIN_NODE" "$RUNNING_JOB"
            return
        fi
        # Declined to reconnect: offer to cancel it, then fall through to launch
        # a new session. Abort if the user keeps the existing job.
        if ! cancel_neurodesk_job "$CTRL_SOCKET" "$LOGIN_NODE" "$RUNNING_JOB"; then
            return 0
        fi
    elif [ -n "$PENDING_JOB" ]; then
        echo "A $JOB_NAME session is already queued and waiting to start (Job $PENDING_JOB)."
        echo "Only one session is supported at a time."
        echo -n "Wait for it to start and attach? [Y/n] "
        read -r waitq
        if [[ ! "$waitq" =~ ^([nN][oO]|[nN])$ ]]; then
            attach_neurodesk_job "$CTRL_SOCKET" "$LOGIN_NODE" "$PENDING_JOB"
            return
        fi
        # Declined to wait: offer to cancel the queued job, then fall through to
        # launch a new session. Abort if the user keeps the existing job.
        if ! cancel_neurodesk_job "$CTRL_SOCKET" "$LOGIN_NODE" "$PENDING_JOB"; then
            return 0
        fi
    fi

    # --- 2. CONFIGURATION FOR NEW CONNECTION ---
    echo "CoreHPC partitions: cpu and gpu. Both have a 96-hour maximum runtime."
    echo -n "Which partition do you want to submit to? [cpu] "
    read -r PARTITION
    PARTITION=${PARTITION:-cpu}
    if [[ ! "$PARTITION" =~ ^(cpu|gpu)$ ]]; then
        echo "Partition must be 'cpu' or 'gpu'."
        return 1
    fi

    echo -n "How much Memory needed? [8G] "
    read -r MEM
    MEM=${MEM:-8G}
    local RAW_MEM="$MEM"
    MEM=$(normalize_memory_request "$MEM")
    if [ "$MEM" != "$RAW_MEM" ]; then
        echo "Interpreting bare memory value '${RAW_MEM}' as '${MEM}'."
    fi
    if [[ ! "$MEM" =~ ^[0-9]+[KMGTP]?$ ]]; then
        echo "Memory must be a Slurm value such as 8G or 500M."
        return 1
    fi

    echo -n "How many CPUs needed? [1] "
    read -r CPUS
    CPUS=${CPUS:-1}
    if [[ ! "$CPUS" =~ ^[1-9][0-9]*$ ]]; then
        echo "CPU count must be a positive integer."
        return 1
    fi

    echo -n "How much time is needed? [02:00:00, maximum 4-00:00:00] "
    read -r WALLTIME
    WALLTIME=${WALLTIME:-02:00:00}
    if ! corehpc_walltime_is_valid "$WALLTIME"; then
        echo "Walltime must be HH:MM:SS or D-HH:MM:SS and no more than 96 hours."
        return 1
    fi

    if [ "$PARTITION" = "gpu" ]; then
        echo -n "How many GPUs are needed? [1] "
        read -r GPU
        GPU=${GPU:-1}
        if [[ ! "$GPU" =~ ^[1-9][0-9]*$ ]]; then
            echo "GPU count must be a positive integer on the gpu partition."
            return 1
        fi
    else
        GPU=none
    fi

    echo -n "Slurm account [cluster default]: "
    read -r SLURM_ACCOUNT
    SLURM_ACCOUNT=${SLURM_ACCOUNT:-${COREHPC_SLURM_ACCOUNT:-}}
    if [ -n "$SLURM_ACCOUNT" ] && [[ ! "$SLURM_ACCOUNT" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "Slurm account contains unsupported characters."
        return 1
    fi

    if ! ensure_corehpc_neurodesktop_image "$CTRL_SOCKET" "$LOGIN_NODE" \
        "$COREHPC_LAB_ROOT" "$NEURODESKTOP_VERSION" "$SLURM_ACCOUNT"; then
        return 1
    fi

    NOTEBOOK_PORT=$(random_tunnel_port)
    if [[ ! "$NOTEBOOK_PORT" =~ ^[0-9]+$ ]]; then
        echo "Failed to choose a notebook port."
        return 1
    fi

    echo "Using random compute-node notebook port: ${NOTEBOOK_PORT}"

    # Authentication token for Jupyter. The compute-node notebook port lives on a
    # shared node's localhost, so we keep token auth on (rather than disabling it)
    # and thread a known token through to the container, the per-job state file,
    # and the URL we print -- so the user can open the notebook in one click.
    local TUNNEL_TOKEN
    TUNNEL_TOKEN=$(random_notebook_token)

    echo "Preparing setup script..."
    ssh -S "$CTRL_SOCKET" "$LOGIN_NODE" "cat > ~/.neurodesk_setup.sh && chmod +x ~/.neurodesk_setup.sh" <<'EOF'
#!/bin/bash
export PATH=$PATH:/sbin:/usr/sbin
: "${COREHPC_LAB_ROOT:?Set COREHPC_LAB_ROOT to your lab storage directory}"
NEURODESKTOP_ASSET_BASE="${HOME%/}/neurodesk"
NEURODESKTOP_HOME_DIR="${NEURODESKTOP_ASSET_BASE}/home"
NEURODESKTOP_WORKDIR="${NEURODESKTOP_HOME_DIR}/workdir"
NEURODESKTOP_CONTAINER_USER="${NEURODESKTOP_CONTAINER_USER:-jovyan}"
NEURODESKTOP_CONTAINER_HOME="${NEURODESKTOP_CONTAINER_HOME:-/home/${NEURODESKTOP_CONTAINER_USER}}"
NEURODESKTOP_START_DIR="${NEURODESKTOP_START_DIR:-${COREHPC_LAB_ROOT}}"

if [ -d "${NEURODESKTOP_ASSET_BASE}/slurm" ]; then
    echo "Removing cached Slurm compatibility assets at ${NEURODESKTOP_ASSET_BASE}/slurm..."
    rm -rf "${NEURODESKTOP_ASSET_BASE}/slurm"
fi

if [ ! -d "${NEURODESKTOP_HOME_DIR}" ]; then
    echo "Creating ${NEURODESKTOP_HOME_DIR}..."
    mkdir -p "${NEURODESKTOP_HOME_DIR}"
else
    echo "${NEURODESKTOP_HOME_DIR} found."
fi

if [ ! -d "${NEURODESKTOP_WORKDIR}" ]; then
    echo "Creating ${NEURODESKTOP_WORKDIR}..."
    mkdir -p "${NEURODESKTOP_WORKDIR}"
else
    echo "${NEURODESKTOP_WORKDIR} found."
fi

if [ ! -d "${NEURODESKTOP_START_DIR}" ]; then
    echo "Requested start dir ${NEURODESKTOP_START_DIR} not found; falling back to ${NEURODESKTOP_WORKDIR}."
    NEURODESKTOP_START_DIR="${NEURODESKTOP_WORKDIR}"
fi
NEURODESKTOP_CONTAINER_WORKDIR="${NEURODESKTOP_CONTAINER_WORKDIR:-${NEURODESKTOP_START_DIR}}"
if ! cd "${NEURODESKTOP_START_DIR}"; then
    echo "ERROR: failed to cd into ${NEURODESKTOP_START_DIR}"
    exit 1
fi
echo "Container start directory target: ${NEURODESKTOP_START_DIR}"
echo "Container working directory path: ${NEURODESKTOP_CONTAINER_WORKDIR}"
echo "Container home mapping: ${NEURODESKTOP_HOME_DIR} -> ${NEURODESKTOP_CONTAINER_HOME}"
echo "Using --writable-tmpfs (ephemeral writable container layer)."

SLURM_BINDS=()
add_slurm_bind() {
    local bind_spec="$1"
    local idx
    for ((idx=1; idx<${#SLURM_BINDS[@]}; idx+=2)); do
        if [ "${SLURM_BINDS[$idx]}" = "${bind_spec}" ]; then
            return
        fi
    done
    SLURM_BINDS+=(--bind "${bind_spec}")
}
# Ensure the notebook start/work directory is available at the same path in the container.
if [ -d "${NEURODESKTOP_START_DIR}" ]; then
    add_slurm_bind "${NEURODESKTOP_START_DIR}:${NEURODESKTOP_START_DIR}"
fi
if [ -d "${COREHPC_LAB_ROOT}" ]; then
    add_slurm_bind "${COREHPC_LAB_ROOT}:${COREHPC_LAB_ROOT}"
else
    echo "ERROR: CoreHPC lab storage is not mounted at ${COREHPC_LAB_ROOT}"
    exit 1
fi
HOST_SLURM_CONF="${SLURM_CONF:-/etc/slurm/slurm.conf}"
HOST_SLURM_CONF_DIR=/etc/slurm
if [ -n "${HOST_SLURM_CONF}" ]; then
    HOST_SLURM_CONF_DIR=$(dirname -- "${HOST_SLURM_CONF}")
fi
HOST_SLURM_CONF_REAL=$(readlink -f "${HOST_SLURM_CONF}" 2>/dev/null || echo "${HOST_SLURM_CONF}")
if [ -z "${HOST_SLURM_CONF_REAL}" ]; then
    HOST_SLURM_CONF_REAL="${HOST_SLURM_CONF}"
fi
HOST_SLURM_CONF_REAL_DIR="${HOST_SLURM_CONF_DIR}"
if [ -n "${HOST_SLURM_CONF_REAL}" ]; then
    HOST_SLURM_CONF_REAL_DIR=$(dirname -- "${HOST_SLURM_CONF_REAL}")
fi
CONTAINER_SLURM_CONF_DIR=/etc/slurm
CONTAINER_SLURM_CONF_PATH="${CONTAINER_SLURM_CONF_DIR}/${HOST_SLURM_CONF_REAL##*/}"
if [ -d "${HOST_SLURM_CONF_REAL_DIR}" ]; then
    add_slurm_bind "${HOST_SLURM_CONF_REAL_DIR}:${CONTAINER_SLURM_CONF_DIR}"
elif [ -d "${HOST_SLURM_CONF_DIR}" ]; then
    add_slurm_bind "${HOST_SLURM_CONF_DIR}:${CONTAINER_SLURM_CONF_DIR}"
fi

SLURM_PLUGIN_DIRS_RAW=""
if [ -r "${HOST_SLURM_CONF_REAL}" ]; then
    SLURM_PLUGIN_DIRS_RAW=$(awk -F= '/^[[:space:]]*PluginDir[[:space:]]*=/{print $2}' "${HOST_SLURM_CONF_REAL}" | tail -n 1 | tr -d '[:space:]')
fi
if [ -z "${SLURM_PLUGIN_DIRS_RAW}" ] && [ -n "${SLURM_PLUGIN_DIR:-}" ]; then
    SLURM_PLUGIN_DIRS_RAW="${SLURM_PLUGIN_DIR}"
fi
if [ -n "${SLURM_PLUGIN_DIRS_RAW}" ]; then
    OLD_IFS="${IFS}"
    IFS=':'
    read -r -a SLURM_PLUGIN_DIRS <<< "${SLURM_PLUGIN_DIRS_RAW}"
    IFS="${OLD_IFS}"
    for plugin_dir in "${SLURM_PLUGIN_DIRS[@]}"; do
        if [ -n "${plugin_dir}" ] && [ -d "${plugin_dir}" ]; then
            add_slurm_bind "${plugin_dir}:${plugin_dir}"
        fi
    done
fi

SLURM_LD_LIBRARY_PATH=""
if [ -z "${NEURODESKTOP_ASSET_BASE:-}" ]; then
    NEURODESKTOP_ASSET_BASE="${HOME%/}/neurodesk"
fi
SLURM_ASSET_ROOT="${NEURODESKTOP_ASSET_BASE}/slurm"
SLURM_HOST_BIN_REAL_STAGING="${SLURM_ASSET_ROOT}/bin-real"
SLURM_HOST_BIN_STAGING="${SLURM_ASSET_ROOT}/bin"
SLURM_HOST_LIB_STAGING="${SLURM_ASSET_ROOT}/libs"
SLURM_WRAPPER_LIB_PATH="/opt/slurm-host-libs"
SLURM_WRAPPER_BIN_PATH="/opt/slurm-host-bin"
unset APPTAINERENV_PREPEND_PATH
unset APPTAINERENV_PATH
resolve_slurm_cmd_path() {
    local slurm_cmd_name="$1"
    local slurm_cmd_path=""
    slurm_cmd_path=$(type -P "${slurm_cmd_name}" 2>/dev/null || true)
    if [ -z "${slurm_cmd_path}" ]; then
        for candidate in /usr/bin /usr/local/bin /bin /usr/sbin /sbin; do
            if [ -x "${candidate}/${slurm_cmd_name}" ]; then
                slurm_cmd_path="${candidate}/${slurm_cmd_name}"
                break
            fi
        done
    fi
    echo "${slurm_cmd_path}"
}
resolve_host_cmd_path() {
    local cmd_name="$1"
    local cmd_path=""
    local login_path=""
    local OLD_IFS

    cmd_path=$(resolve_slurm_cmd_path "${cmd_name}")
    if [ -n "${cmd_path}" ] && [ -x "${cmd_path}" ]; then
        echo "${cmd_path}"
        return
    fi

    # In non-login shells on some clusters, PATH can miss helper locations.
    login_path=$(bash -lc 'printf "%s" "$PATH"' 2>/dev/null || true)
    if [ -n "${login_path}" ]; then
        OLD_IFS="${IFS}"
        IFS=':'
        read -r -a login_dirs <<< "${login_path}"
        IFS="${OLD_IFS}"
        for login_dir in "${login_dirs[@]}"; do
            [ -z "${login_dir}" ] && continue
            if [ -x "${login_dir}/${cmd_name}" ]; then
                echo "${login_dir}/${cmd_name}"
                return
            fi
        done
    fi

    for candidate in \
        /share/software/user/open/bin \
        /share/software/user/bin \
        /usr/local/bin \
        /usr/bin \
        /bin \
        /usr/sbin \
        /sbin
    do
        if [ -x "${candidate}/${cmd_name}" ]; then
            echo "${candidate}/${cmd_name}"
            return
        fi
    done

    echo ""
}
copy_host_library_dep() {
    local dep_path="$1"
    local dep_base
    [ -z "${dep_path}" ] && return
    [ -r "${dep_path}" ] || return
    dep_base=$(basename "${dep_path}")
    case "${dep_base}" in
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*.so.*)
            return
            ;;
    esac
    cp -Lf "${dep_path}" "${SLURM_HOST_LIB_STAGING}/${dep_base}" 2>/dev/null || true
}
resolve_missing_library_dep() {
    local dep_name="$1"
    local dep_path=""
    local dep_dir
    if command -v ldconfig >/dev/null 2>&1; then
        dep_path=$(ldconfig -p 2>/dev/null | awk -v lib="${dep_name}" '$1 == lib {print $NF; exit}')
    fi
    if [ -n "${dep_path}" ] && [ -r "${dep_path}" ]; then
        echo "${dep_path}"
        return
    fi
    for dep_dir in /usr/lib64 /lib64 /usr/lib /lib /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        if [ -r "${dep_dir}/${dep_name}" ]; then
            echo "${dep_dir}/${dep_name}"
            return
        fi
    done
    echo ""
}
copy_binary_dependencies() {
    local bin_path="$1"
    local dep_path
    local dep_name
    local resolved_path
    while read -r dep_path; do
        [ -z "${dep_path}" ] && continue
        copy_host_library_dep "${dep_path}"
    done < <(ldd "${bin_path}" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}')
    while read -r dep_name; do
        [ -z "${dep_name}" ] && continue
        resolved_path=$(resolve_missing_library_dep "${dep_name}")
        if [ -n "${resolved_path}" ]; then
            copy_host_library_dep "${resolved_path}"
        fi
    done < <(ldd "${bin_path}" 2>/dev/null | awk '$2 == "=>" && $3 == "not" && $4 == "found" {print $1}')
}
copy_library_family_dependencies() {
    local lib_prefix="$1"
    local dep_dir
    local dep_path
    for dep_dir in /usr/lib64 /lib64 /usr/lib /lib /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        [ -d "${dep_dir}" ] || continue
        while read -r dep_path; do
            [ -z "${dep_path}" ] && continue
            copy_host_library_dep "${dep_path}"
        done < <(find "${dep_dir}" -maxdepth 1 -type f -name "${lib_prefix}*.so*" 2>/dev/null)
    done
}
file_mtime_epoch() {
    local path="$1"
    if [ ! -e "${path}" ]; then
        echo 0
        return
    fi
    stat -c %Y "${path}" 2>/dev/null || stat -f %m "${path}" 2>/dev/null || echo 0
}
hash_text_value() {
    local value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "${value}" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "${value}" | cksum | awk '{print $1}'
    fi
}
if command -v ldd >/dev/null 2>&1; then
    SLURM_HOST_CMDS=(sinfo squeue scontrol sacct srun sbatch scancel salloc sstat sprio quota lfs)
    SLURM_CACHE_DIR="${SLURM_ASSET_ROOT}/cache"
    SLURM_CACHE_SIG_FILE="${SLURM_CACHE_DIR}/signature.txt"
    SLURM_CACHE_TTL_SECONDS="${NEURODESKTOP_SLURM_CACHE_TTL_SECONDS:-86400}"
    if [[ ! "${SLURM_CACHE_TTL_SECONDS}" =~ ^[0-9]+$ ]]; then
        SLURM_CACHE_TTL_SECONDS=86400
    fi
    mkdir -p "${SLURM_CACHE_DIR}"
    mkdir -p "${SLURM_HOST_BIN_REAL_STAGING}"
    mkdir -p "${SLURM_HOST_BIN_STAGING}"
    mkdir -p "${SLURM_HOST_LIB_STAGING}"
    SLURM_CACHE_INPUT="host=$(hostname 2>/dev/null || echo unknown)
slurm_conf=${HOST_SLURM_CONF_REAL}
slurm_conf_mtime=$(file_mtime_epoch "${HOST_SLURM_CONF_REAL}")
plugin_dirs=${SLURM_PLUGIN_DIRS_RAW:-unset}"
    for plugin_dir in "${SLURM_PLUGIN_DIRS[@]}"; do
        [ -z "${plugin_dir}" ] && continue
        SLURM_CACHE_INPUT="${SLURM_CACHE_INPUT}
plugin_dir=${plugin_dir}|mtime=$(file_mtime_epoch "${plugin_dir}")"
    done
    for slurm_cmd in "${SLURM_HOST_CMDS[@]}"; do
        cmd_path=$(resolve_slurm_cmd_path "${slurm_cmd}")
        SLURM_CACHE_INPUT="${SLURM_CACHE_INPUT}
cmd=${slurm_cmd}|path=${cmd_path:-missing}|mtime=$(file_mtime_epoch "${cmd_path}")"
    done
    SLURM_CACHE_SIGNATURE=$(hash_text_value "${SLURM_CACHE_INPUT}")

    NEED_CACHE_REBUILD=1
    CACHE_COMMAND_WRAPPERS_OK=1
    for slurm_cmd in "${SLURM_HOST_CMDS[@]}"; do
        cmd_path=$(resolve_slurm_cmd_path "${slurm_cmd}")
        if [ -n "${cmd_path}" ] && [ -x "${cmd_path}" ]; then
            if [ ! -x "${SLURM_HOST_BIN_STAGING}/${slurm_cmd}" ] || \
               [ ! -e "${SLURM_HOST_BIN_REAL_STAGING}/${slurm_cmd}" ]; then
                CACHE_COMMAND_WRAPPERS_OK=0
                break
            fi
        fi
    done
    if [ -f "${SLURM_CACHE_SIG_FILE}" ] && [ -s "${SLURM_CACHE_SIG_FILE}" ]; then
        CACHED_SIGNATURE=$(head -n 1 "${SLURM_CACHE_SIG_FILE}" 2>/dev/null || echo "")
        CACHE_SIG_MTIME=$(file_mtime_epoch "${SLURM_CACHE_SIG_FILE}")
        CACHE_NOW_EPOCH=$(date +%s)
        CACHE_AGE=$((CACHE_NOW_EPOCH - CACHE_SIG_MTIME))
        if [ "${CACHED_SIGNATURE}" = "${SLURM_CACHE_SIGNATURE}" ] && \
           [ "${CACHE_AGE}" -ge 0 ] && [ "${CACHE_AGE}" -le "${SLURM_CACHE_TTL_SECONDS}" ] && \
           ls "${SLURM_HOST_BIN_REAL_STAGING}"/* >/dev/null 2>&1 && \
           ls "${SLURM_HOST_BIN_STAGING}"/* >/dev/null 2>&1 && \
           [ "${CACHE_COMMAND_WRAPPERS_OK}" -eq 1 ]; then
            NEED_CACHE_REBUILD=0
        fi
    fi

    if [ "${NEED_CACHE_REBUILD}" -eq 1 ]; then
        echo "Preparing host Slurm compatibility assets (initial run or cache refresh)..."
        rm -f "${SLURM_HOST_BIN_REAL_STAGING}"/* 2>/dev/null || true
        rm -f "${SLURM_HOST_BIN_STAGING}"/* 2>/dev/null || true
        rm -f "${SLURM_HOST_LIB_STAGING}"/*.so* 2>/dev/null || true

        echo "Scanning host Slurm command dependencies..."
        for slurm_cmd in "${SLURM_HOST_CMDS[@]}"; do
            cmd_path=$(resolve_slurm_cmd_path "${slurm_cmd}")
            if [ -n "${cmd_path}" ] && [ -x "${cmd_path}" ]; then
                cp -Lf "${cmd_path}" "${SLURM_HOST_BIN_REAL_STAGING}/${slurm_cmd}" 2>/dev/null || true
                printf '%s\n' \
                    '#!/bin/bash' \
                    "export LD_LIBRARY_PATH=${SLURM_WRAPPER_LIB_PATH}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}" \
                    '# Prevent sbatch/srun/salloc from exporting the current Neurodesktop container runtime into new host jobs.' \
                    "if [ \"${slurm_cmd}\" = \"sbatch\" ] || [ \"${slurm_cmd}\" = \"salloc\" ] || [ \"${slurm_cmd}\" = \"srun\" ]; then" \
                    '    while IFS= read -r env_name; do' \
                    '        case "${env_name}" in' \
                    '            APPTAINER*|SINGULARITY*)' \
                    '                unset "${env_name}"' \
                    '                ;;' \
                    '        esac' \
                    '    done < <(compgen -e)' \
                    '    for tmp_name in TMPDIR TMP TEMP TEMPDIR; do' \
                    '        tmp_value="${!tmp_name:-}"' \
                    '        case "${tmp_value}" in' \
                    '            /tmp/apptainer_*|/var/tmp/apptainer_*)' \
                    '                if [ ! -e "${tmp_value}" ]; then' \
                    '                    unset "${tmp_name}"' \
                    '                fi' \
                    '                ;;' \
                    '        esac' \
                    '    done' \
                    'fi' \
                    "exec /opt/slurm-host-bin-real/${slurm_cmd} \"\$@\"" \
                    > "${SLURM_HOST_BIN_STAGING}/${slurm_cmd}"
                chmod +x "${SLURM_HOST_BIN_STAGING}/${slurm_cmd}" 2>/dev/null || true
                copy_binary_dependencies "${cmd_path}"
            fi
        done

        if [ -n "${SLURM_PLUGIN_DIRS_RAW}" ]; then
            echo "Scanning Slurm plugin dependencies..."
        fi
        for plugin_dir in "${SLURM_PLUGIN_DIRS[@]}"; do
            [ -d "${plugin_dir}" ] || continue
            while read -r plugin_file; do
                [ -r "${plugin_file}" ] || continue
                copy_binary_dependencies "${plugin_file}"
            done < <(find "${plugin_dir}" -maxdepth 4 -type f -name '*.so*' 2>/dev/null)
        done

        # lfs can dlopen Lustre libraries that may not appear in ldd output.
        copy_library_family_dependencies liblustre
        copy_library_family_dependencies liblnet

        printf '%s\n' "${SLURM_CACHE_SIGNATURE}" > "${SLURM_CACHE_SIG_FILE}"
    else
        echo "Using cached host Slurm compatibility assets."
    fi

    if ls "${SLURM_HOST_BIN_REAL_STAGING}"/* >/dev/null 2>&1; then
        add_slurm_bind "${SLURM_HOST_BIN_REAL_STAGING}:/opt/slurm-host-bin-real"
    fi
    if ls "${SLURM_HOST_BIN_STAGING}"/* >/dev/null 2>&1; then
        add_slurm_bind "${SLURM_HOST_BIN_STAGING}:${SLURM_WRAPPER_BIN_PATH}"
        export APPTAINERENV_PREPEND_PATH="${SLURM_WRAPPER_BIN_PATH}"
        # Explicitly set PATH to keep wrapper precedence even if startup scripts reset PATH.
        export APPTAINERENV_PATH="${SLURM_WRAPPER_BIN_PATH}:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    fi
    for slurm_cmd in "${SLURM_HOST_CMDS[@]}"; do
        cmd_path=$(resolve_slurm_cmd_path "${slurm_cmd}")
        if [ -n "${cmd_path}" ] && [ -x "${cmd_path}" ] && [ -x "${SLURM_HOST_BIN_STAGING}/${slurm_cmd}" ]; then
            # Force replacement of container slurm client command paths so PATH changes cannot bypass wrappers.
            add_slurm_bind "${SLURM_HOST_BIN_STAGING}/${slurm_cmd}:${cmd_path}"
        fi
    done
    if ls "${SLURM_HOST_LIB_STAGING}"/*.so* >/dev/null 2>&1; then
        add_slurm_bind "${SLURM_HOST_LIB_STAGING}:${SLURM_WRAPPER_LIB_PATH}"
        SLURM_LD_LIBRARY_PATH="${SLURM_WRAPPER_LIB_PATH} (wrapper scoped)"
    fi

    # Ensure legacy cached sh_quota wrappers do not survive cache reuse.
    rm -f "${SLURM_HOST_BIN_REAL_STAGING}/sh_quota" 2>/dev/null || true

    # Install a clean sh_quota shim into wrapper PATH that explicitly unsets
    # LD_LIBRARY_PATH before executing the host helper.
    HOST_SH_QUOTA_PATH=$(resolve_host_cmd_path sh_quota)
    if [ -n "${HOST_SH_QUOTA_PATH}" ] && [ -x "${HOST_SH_QUOTA_PATH}" ]; then
        cat > "${SLURM_HOST_BIN_STAGING}/sh_quota" <<__NEURODESK_SH_QUOTA_WRAPPER__
#!/bin/bash
unset LD_LIBRARY_PATH
HOST_SH_QUOTA_PATH="${HOST_SH_QUOTA_PATH}"
HOST_HOME_PATH="${HOME}"
lfs_cmd=/opt/slurm-host-bin/lfs
if [ ! -x "\${lfs_cmd}" ]; then
    lfs_cmd=/bin/lfs
fi
srun_cmd=/opt/slurm-host-bin/srun
if [ ! -x "\${srun_cmd}" ]; then
    srun_cmd=/usr/bin/srun
fi

run_host_quota_via_srun() {
    local out status
    [ -n "\${SLURM_JOB_ID:-}" ] || return 1
    [ -x "\${srun_cmd}" ] || return 1
    out=\$(HOME="\${HOST_HOME_PATH}" SLURM_MPI_TYPE=none "\${srun_cmd}" \
        --jobid "\${SLURM_JOB_ID}" \
        --overlap \
        --nodes=1 \
        --ntasks=1 \
        --mpi=none \
        --export=ALL,HOME="\${HOST_HOME_PATH}" \
        --quiet \
        --chdir "\${PWD}" \
        "\${HOST_SH_QUOTA_PATH}" "\$@" 2>&1)
    status=\$?
    if [ "\${status}" -eq 0 ]; then
        printf '%s\n' "\${out}"
        return 0
    fi
    return "\${status}"
}

print_filtered_host_quota() {
    local out status
    out=\$(HOME="\${HOST_HOME_PATH}" "\${HOST_SH_QUOTA_PATH}" "\$@" 2>&1)
    status=\$?
    printf '%s\n' "\${out}" | awk '
        \$0 == "error: unsupported filesystem lustre" { next }
        \$0 == "error: unsupported filesystem nfs4" { next }
        \$0 == "lustre" { next }
        \$0 == "nfs4" { next }
        { print }
    '
    return "\${status}"
}

print_lustre_fallback() {
    local label="\$1"
    local path="\$2"
    local out
    [ -n "\${path}" ] || return 1
    [ -x "\${lfs_cmd}" ] || return 1
    out=\$("\${lfs_cmd}" quota -u "\${USER}" "\${path}" 2>&1) || return 1
    printf '%s\n' "+---------------------------------------------------------------------------+"
    printf '| %-73s |\n' "\${label} quota fallback via lfs (\${path})"
    printf '%s\n' "+---------------------------------------------------------------------------+"
    printf '%s\n' "\${out}"
    return 0
}

if run_host_quota_via_srun "\$@"; then
    exit 0
fi

if [ "\$1" = "-f" ] && [ -n "\$2" ]; then
    fs_name=\$(printf '%s' "\$2" | tr '[:lower:]' '[:upper:]')
    case "\${fs_name}" in
        SCRATCH)
            if print_lustre_fallback SCRATCH "\${SCRATCH:-\${COREHPC_LAB_ROOT:-}}"; then
                exit 0
            fi
            ;;
        GROUP_SCRATCH)
            if print_lustre_fallback GROUP_SCRATCH "\${GROUP_SCRATCH:-}"; then
                exit 0
            fi
            ;;
    esac
    print_filtered_host_quota "\$@"
    exit \$?
fi

if [ "\$#" -gt 0 ]; then
    print_filtered_host_quota "\$@"
    exit \$?
fi

host_output=\$(print_filtered_host_quota)
host_status=\$?
printf '%s\n' "\${host_output}"

fallback_printed=0
if ! printf '%s\n' "\${host_output}" | grep -Eq '^[[:space:]]*SCRATCH[[:space:]]*\\|'; then
    if print_lustre_fallback SCRATCH "\${SCRATCH:-\${COREHPC_LAB_ROOT:-}}"; then
        fallback_printed=1
    fi
fi
if ! printf '%s\n' "\${host_output}" | grep -Eq '^[[:space:]]*GROUP_SCRATCH[[:space:]]*\\|'; then
    if print_lustre_fallback GROUP_SCRATCH "\${GROUP_SCRATCH:-}"; then
        fallback_printed=1
    fi
fi

if [ "\${fallback_printed}" -eq 1 ]; then
    exit 0
fi
exit "\${host_status}"
__NEURODESK_SH_QUOTA_WRAPPER__
        chmod +x "${SLURM_HOST_BIN_STAGING}/sh_quota" 2>/dev/null || true
        add_slurm_bind "${HOST_SH_QUOTA_PATH}:${HOST_SH_QUOTA_PATH}"
        # Keep sh_quota available even if PATH inside the container is reset.
        add_slurm_bind "${SLURM_HOST_BIN_STAGING}/sh_quota:/usr/local/bin/sh_quota"
    else
        rm -f "${SLURM_HOST_BIN_STAGING}/sh_quota" 2>/dev/null || true
        echo "WARNING: host sh_quota command not found in current/login PATH."
    fi
    if [ -x "${SLURM_HOST_BIN_STAGING}/quota" ]; then
        # sh_quota may call quota via different absolute paths.
        for quota_path in /usr/bin/quota /usr/sbin/quota /bin/quota /sbin/quota; do
            if [ -x "${quota_path}" ]; then
                add_slurm_bind "${SLURM_HOST_BIN_STAGING}/quota:${quota_path}"
            fi
        done
    fi
    if [ -x "${SLURM_HOST_BIN_STAGING}/lfs" ]; then
        # sh_quota can call /bin/lfs or /usr/bin/lfs.
        add_slurm_bind "${SLURM_HOST_BIN_STAGING}/lfs:/bin/lfs"
        add_slurm_bind "${SLURM_HOST_BIN_STAGING}/lfs:/usr/bin/lfs"
    else
        HOST_LFS_PATH=$(resolve_host_cmd_path lfs)
        if [ -n "${HOST_LFS_PATH}" ] && [ -x "${HOST_LFS_PATH}" ]; then
            echo "WARNING: using unwrapped host lfs at ${HOST_LFS_PATH}; Lustre libs may be missing in container."
            add_slurm_bind "${HOST_LFS_PATH}:/bin/lfs"
            add_slurm_bind "${HOST_LFS_PATH}:/usr/bin/lfs"
        else
            echo "WARNING: host lfs command not found; sh_quota may not report Lustre quotas."
        fi
    fi
fi
if [ -e /run/slurm ]; then
    add_slurm_bind /run/slurm:/run/slurm
fi
if [ -e /run/slurmctld ]; then
    add_slurm_bind /run/slurmctld:/run/slurmctld
fi
if [ -e /run/slurmdbd ]; then
    add_slurm_bind /run/slurmdbd:/run/slurmdbd
fi

CLUSTER_NAME=""
if [ -r "${HOST_SLURM_CONF_REAL}" ]; then
    CLUSTER_NAME=$(awk -F= '/^[[:space:]]*ClusterName[[:space:]]*=/{print $2}' "${HOST_SLURM_CONF_REAL}" | tail -n 1 | tr -d '[:space:]')
fi
if [ -n "${CLUSTER_NAME}" ] && [ -e "/run/slurm-${CLUSTER_NAME}" ]; then
    add_slurm_bind "/run/slurm-${CLUSTER_NAME}:/run/slurm-${CLUSTER_NAME}"
fi

SACK_SOCKET_CANDIDATE="${SLURM_SACK_SOCKET:-}"
if [ -z "${SACK_SOCKET_CANDIDATE}" ]; then
    if [ -n "${CLUSTER_NAME}" ] && [ -S "/run/slurm-${CLUSTER_NAME}/sack.socket" ]; then
        SACK_SOCKET_CANDIDATE="/run/slurm-${CLUSTER_NAME}/sack.socket"
    elif [ -S /run/slurm/sack.socket ]; then
        SACK_SOCKET_CANDIDATE=/run/slurm/sack.socket
    elif [ -S /run/slurmctld/sack.socket ]; then
        SACK_SOCKET_CANDIDATE=/run/slurmctld/sack.socket
    elif [ -S /run/slurmdbd/sack.socket ]; then
        SACK_SOCKET_CANDIDATE=/run/slurmdbd/sack.socket
    else
        SACK_SOCKET_CANDIDATE=$(find /run -maxdepth 4 -type s -name 'sack.socket' 2>/dev/null | head -n 1)
    fi
fi
if [ -n "${SACK_SOCKET_CANDIDATE}" ] && [ -S "${SACK_SOCKET_CANDIDATE}" ]; then
    SACK_SOCKET_DIR=$(dirname "${SACK_SOCKET_CANDIDATE}")
    if [ -d "${SACK_SOCKET_DIR}" ]; then
        add_slurm_bind "${SACK_SOCKET_DIR}:${SACK_SOCKET_DIR}"
    fi
fi
if [ -e /run/munge ]; then
    add_slurm_bind /run/munge:/run/munge
fi
if [ -e /var/run/munge ]; then
    add_slurm_bind /var/run/munge:/var/run/munge
fi

MUNGE_SOCKET_CANDIDATE="${MUNGE_SOCKET:-}"
if [ -z "${MUNGE_SOCKET_CANDIDATE}" ]; then
    for sock in \
        /run/munge/munge.socket.2 \
        /var/run/munge/munge.socket.2 \
        /run/munge/munge.socket \
        /var/run/munge/munge.socket \
        /var/spool/slurmd/munge.socket.2 \
        /var/spool/slurm/munge.socket.2
    do
        if [ -S "${sock}" ]; then
            MUNGE_SOCKET_CANDIDATE="${sock}"
            break
        fi
    done
fi
if [ -n "${MUNGE_SOCKET_CANDIDATE}" ] && [ -S "${MUNGE_SOCKET_CANDIDATE}" ]; then
    MUNGE_SOCKET_DIR=$(dirname "${MUNGE_SOCKET_CANDIDATE}")
    if [ -d "${MUNGE_SOCKET_DIR}" ]; then
        add_slurm_bind "${MUNGE_SOCKET_DIR}:${MUNGE_SOCKET_DIR}"
    fi
fi

export APPTAINERENV_NEURODESKTOP_SLURM_MODE=host
export APPTAINERENV_SLURM_CONF="${CONTAINER_SLURM_CONF_PATH}"
unset APPTAINERENV_LD_LIBRARY_PATH
if [ -n "${SACK_SOCKET_CANDIDATE}" ] && [ -S "${SACK_SOCKET_CANDIDATE}" ]; then
    export APPTAINERENV_SLURM_SACK_SOCKET="${SACK_SOCKET_CANDIDATE}"
else
    unset APPTAINERENV_SLURM_SACK_SOCKET
fi

if [ -n "${MUNGE_SOCKET_CANDIDATE}" ] && [ -S "${MUNGE_SOCKET_CANDIDATE}" ]; then
    export APPTAINERENV_MUNGE_SOCKET="${MUNGE_SOCKET_CANDIDATE}"
else
    unset APPTAINERENV_MUNGE_SOCKET
fi

echo "Host Slurm integration: mode=${APPTAINERENV_NEURODESKTOP_SLURM_MODE:-unset} conf=${APPTAINERENV_SLURM_CONF:-unset} (from ${HOST_SLURM_CONF}) sack=${APPTAINERENV_SLURM_SACK_SOCKET:-unset} munge=${APPTAINERENV_MUNGE_SOCKET:-unset}"
echo "Host Slurm plugin dirs: ${SLURM_PLUGIN_DIRS_RAW:-unset}"
echo "Host Slurm bin dir: ${APPTAINERENV_PREPEND_PATH:-unset}"
echo "Host Slurm PATH: ${APPTAINERENV_PATH:-unset}"
echo "Host Slurm loader dirs: ${SLURM_LD_LIBRARY_PATH:-unset}"
echo "Host Slurm wrapper count: $(ls "$SLURM_HOST_BIN_STAGING" 2>/dev/null | wc -l | tr -d ' ')"
if [ -e "${HOST_SLURM_CONF_REAL}" ]; then
    ls -l "${HOST_SLURM_CONF_REAL}"
else
    echo "WARNING: host slurm.conf not found at ${HOST_SLURM_CONF_REAL}"
fi

echo "Starting Neurodesktop container..."
NEURODESKTOP_NOTEBOOK_PORT="${NEURODESKTOP_NOTEBOOK_PORT:-8888}"
NEURODESKTOP_DISPLAY_URL="${NEURODESKTOP_DISPLAY_URL:-http://127.0.0.1:8888}"
NEURODESKTOP_TOKEN="${NEURODESKTOP_TOKEN:-}"
# Show a clickable, token-bearing URL in the container/Jupyter log.
if [ -n "${NEURODESKTOP_TOKEN}" ]; then
    NEURODESKTOP_DISPLAY_URL="${NEURODESKTOP_DISPLAY_URL%/}/lab?token=${NEURODESKTOP_TOKEN}"
fi
NEURODESKTOP_DISABLE_JPSERVER_EXTENSIONS="${NEURODESKTOP_DISABLE_JPSERVER_EXTENSIONS:-{'jupyter_server_fileid': False, 'jupyter_server_ydoc': False}}"
# Name the actual compute node in the prompt. A prompt reading "corehpc" invites
# running downloads here, but compute nodes have no route to chpc-proxy-vm1, so
# anything network-touching must run on the login node instead.
NEURODESKTOP_NODE_LABEL="$(hostname -s 2>/dev/null || echo compute)"
NEURODESKTOP_SHELL_PROMPT="${NEURODESKTOP_SHELL_PROMPT:-neurodesk@${NEURODESKTOP_NODE_LABEL}(no-internet):\\w\\$ }"

# FreeSurfer refuses to run without a license. The lab root is bound at the same
# path inside the container, so this location is valid on both sides.
NEURODESKTOP_FS_LICENSE="${NEURODESKTOP_FS_LICENSE:-${COREHPC_LAB_ROOT}/neurodesk/freesurfer_license.txt}"
if [ ! -s "${NEURODESKTOP_FS_LICENSE}" ]; then
    echo "[WARN] No FreeSurfer license at ${NEURODESKTOP_FS_LICENSE}"
    echo "[WARN] FreeSurfer tools will refuse to run. Get one free at:"
    echo "[WARN]   https://surfer.nmr.mgh.harvard.edu/registration.html"
    echo "[WARN] then save it to that path; no need to restart this session."
fi

port_in_use_on_host() {
    local port="$1"

    if [ -z "${port}" ]; then
        return 1
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t >/dev/null 2>&1
        return $?
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR>1 {found=1} END {exit(found ? 0 : 1)}'
        return $?
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -Eq "[\\.:]${port}[[:space:]].*LISTEN"
        return $?
    fi

    return 1
}

if port_in_use_on_host "${NEURODESKTOP_NOTEBOOK_PORT}"; then
    echo "ERROR: notebook port ${NEURODESKTOP_NOTEBOOK_PORT} is already in use on $(hostname)."
    echo "Please rerun the CoreHPC connect script to pick a different notebook port."
    exit 1
fi

NEURODESKTOP_UID=$(id -u)
NEURODESKTOP_GID=$(id -g)
NEURODESKTOP_ENABLE_GPU="${NEURODESKTOP_ENABLE_GPU:-0}"
APPTAINER_GPU_ARGS=()
if [ "${NEURODESKTOP_ENABLE_GPU}" = "1" ]; then
    APPTAINER_GPU_ARGS+=(--nv)
    if [ -d /dev/dri ]; then
        APPTAINER_GPU_ARGS+=(--bind /dev/dri:/dev/dri)
    fi
    export APPTAINERENV_NVIDIA_DRIVER_CAPABILITIES=all
    if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
        export APPTAINERENV_CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}"
    fi
    if [ -n "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
        export APPTAINERENV_NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES}"
    elif [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
        export APPTAINERENV_NVIDIA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES}"
    fi
    echo "GPU passthrough enabled for container (--nv)."
else
    unset APPTAINERENV_CUDA_VISIBLE_DEVICES
    unset APPTAINERENV_NVIDIA_VISIBLE_DEVICES
    echo "GPU passthrough disabled for container."
fi

NEURODESKTOP_SHARED_CONTAINER_STORE="${COREHPC_LAB_ROOT}/neurodesk/local/containers"
NEURODESKTOP_IMAGE="${NEURODESKTOP_IMAGE:-${COREHPC_LAB_ROOT}/neurodesk/neurodesktop_latest.sif}"
if ! mkdir -p "${NEURODESKTOP_SHARED_CONTAINER_STORE}"; then
    echo "ERROR: cannot create the shared container store at ${NEURODESKTOP_SHARED_CONTAINER_STORE}"
    exit 1
fi
if [ ! -s "${NEURODESKTOP_IMAGE}" ]; then
    echo "ERROR: Neurodesktop image is missing or empty: ${NEURODESKTOP_IMAGE}"
    exit 1
fi
CONTAINER_STORE_BIND_SPEC="${NEURODESKTOP_SHARED_CONTAINER_STORE}:${NEURODESKTOP_SHARED_CONTAINER_STORE}"
CONTAINER_STORE_NEURODESKTOP_BIND_SPEC="${NEURODESKTOP_SHARED_CONTAINER_STORE}:/neurodesktop-storage/containers"
echo "Shared container store mapping: ${CONTAINER_STORE_BIND_SPEC}"
echo "Neurodesktop container store mapping: ${CONTAINER_STORE_NEURODESKTOP_BIND_SPEC}"

unset APPTAINERENV_HOME
echo "Jupyter trash is disabled; deletes are permanent."
apptainer run \
   "${APPTAINER_GPU_ARGS[@]}" \
   --writable-tmpfs \
   --bind "${CONTAINER_STORE_BIND_SPEC}" \
   --bind "${CONTAINER_STORE_NEURODESKTOP_BIND_SPEC}" \
   "${SLURM_BINDS[@]}" \
   --home "${NEURODESKTOP_HOME_DIR}:${NEURODESKTOP_CONTAINER_HOME}" \
   --pwd "${NEURODESKTOP_CONTAINER_WORKDIR}" \
   --env CVMFS_DISABLE=true \
   --env FS_LICENSE="${NEURODESKTOP_FS_LICENSE}" \
   --env TINI_SUBREAPER=1 \
   --env NB_UID="${NEURODESKTOP_UID}" \
   --env NB_GID="${NEURODESKTOP_GID}" \
   --env PS1="${NEURODESKTOP_SHELL_PROMPT}" \
   --env NEURODESKTOP_LOCAL_CONTAINERS="${NEURODESKTOP_SHARED_CONTAINER_STORE}" \
   "${NEURODESKTOP_IMAGE}" \
   start-notebook.py \
      --ServerApp.port="${NEURODESKTOP_NOTEBOOK_PORT}" \
      --ServerApp.port_retries=0 \
      --IdentityProvider.token="${NEURODESKTOP_TOKEN}" \
      --ServerApp.custom_display_url="${NEURODESKTOP_DISPLAY_URL}" \
      --FileContentsManager.delete_to_trash=False \
      --ServerApp.jpserver_extensions="${NEURODESKTOP_DISABLE_JPSERVER_EXTENSIONS}"
EOF

    # --- 4. LAUNCH ALLOCATION ---
    local GPU_FLAG=""
    local ACCOUNT_FLAG=""
    local ENABLE_GPU_CONTAINER=0
    if [[ -n "$GPU" && ! "$GPU" =~ ^([nN][oO][nN][eE]|0)$ ]]; then
        GPU_FLAG="--gres=gpu:$GPU"
        ENABLE_GPU_CONTAINER=1
    fi
    if [ -n "$SLURM_ACCOUNT" ]; then
        ACCOUNT_FLAG="--account=$SLURM_ACCOUNT"
    fi

    # The wrapper runs on the allocated compute node. It records the node and
    # notebook port so a later invocation can rebuild the tunnel, then starts
    # the container.
    if ! ssh -S "$CTRL_SOCKET" "$LOGIN_NODE" "cat > ~/.neurodesk_job.sh && chmod +x ~/.neurodesk_job.sh" <<'EOF'
#!/bin/bash
# Per-job state file keyed by SLURM_JOB_ID so concurrent neurodesktop jobs do
# not clobber each other's recorded node/port.
STATE_FILE="${HOME}/.neurodesk_session_${SLURM_JOB_ID}.env"
umask 077
cat > "${STATE_FILE}" <<STATE
NEURODESK_JOB_ID=${SLURM_JOB_ID}
NEURODESK_NODE=$(hostname -s)
NEURODESK_PORT=${NEURODESKTOP_NOTEBOOK_PORT}
NEURODESK_TOKEN=${NEURODESKTOP_TOKEN:-}
STATE
exec "${HOME}/.neurodesk_setup.sh"
EOF
    then
        echo "Failed to upload session wrapper (~/.neurodesk_job.sh) to $LOGIN_NODE."
        return 1
    fi

    local SUBMIT_OUTPUT SUBMIT_STATUS JOB_ID
    SUBMIT_OUTPUT=$(ssh -S "$CTRL_SOCKET" -q "$LOGIN_NODE" \
        "sbatch --parsable --job-name=$JOB_NAME -p $PARTITION --nodes=1 --time=$WALLTIME \
         --ntasks=1 --cpus-per-task=$CPUS --mem=$MEM $GPU_FLAG $ACCOUNT_FLAG \
         --output=\$HOME/.neurodesk_job_%j.log \
         --export=ALL,COREHPC_LAB_ROOT=${COREHPC_LAB_ROOT},NEURODESKTOP_ENABLE_GPU=${ENABLE_GPU_CONTAINER},NEURODESKTOP_NOTEBOOK_PORT=${NOTEBOOK_PORT},NEURODESKTOP_TOKEN=${TUNNEL_TOKEN},NEURODESKTOP_DISPLAY_URL=http://127.0.0.1:${NOTEBOOK_PORT} \
         ~/.neurodesk_job.sh")
    SUBMIT_STATUS=$?
    # --parsable prints "<jobid>" or "<jobid>;<cluster>"; take the field before ';'.
    JOB_ID=${SUBMIT_OUTPUT%%;*}
    JOB_ID=${JOB_ID//[[:space:]]/}
    if [ "$SUBMIT_STATUS" -ne 0 ] || [[ ! "$JOB_ID" =~ ^[0-9]+$ ]]; then
        echo "Failed to submit batch job (exit $SUBMIT_STATUS). sbatch said: $SUBMIT_OUTPUT"
        return 1
    fi

    echo "Submitted batch job $JOB_ID. Waiting for it to start (Ctrl-C is safe; the job keeps running)..."
    attach_neurodesk_job "$CTRL_SOCKET" "$LOGIN_NODE" "$JOB_ID"
}

# Check if the script is being executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    connectUCSFcoreHPC "$@"
fi
