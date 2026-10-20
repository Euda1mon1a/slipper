#!/bin/bash
# Slipper launcher. Starts the server described in slipper.conf (next to this file), opens
# the browser once the server answers, and stops the server when this window closes or on
# Ctrl-C. The same file is copied unchanged into every app; only slipper.conf differs.
unset CDPATH

case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
APP_WORKDIR="" APP_VENV="" APP_INSTALL_CMD="" APP_WAIT_SECONDS=30
. "$here/slipper.conf" || { echo "Can't read $here/slipper.conf"; exit 1; }

# State is keyed on the app's ID and its own path, so a duplicated or moved copy keeps its
# own install record and pidfile.
bundle=$(cd -P -- "$here/../.." && pwd -P && echo .) || { echo "Can't find this app's folder"; exit 1; }
bundle=${bundle%??}
key="$APP_ID-$(printf '%s' "$bundle" | shasum -a 256 | cut -c1-16)"
state="$HOME/Library/Application Support/Slipper"
pidfile="$state/$key.pid"
installed="$state/$key.installed"

# PIDs listening on the app's port (not clients connected to it).
listeners() {
    lsof -nP -iTCP:"$APP_PORT" -sTCP:LISTEN -t 2>/dev/null
}

# True when process $1 is process $2 or one of its descendants.
descends_from() {
    local p=$1
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        [ "$p" = "$2" ] && return 0
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    return 1
}

# Ask a process and its children to stop (TERM only; this launcher never sends KILL).
stop_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        stop_tree "$child"
    done
    kill -TERM "$1" 2>/dev/null
}

printf '%s\n\n' "$APP_NAME"

# Something already on the port: reopen the browser if it is the server this app started
# last time, otherwise ask before stopping it. Anything not started by this app's start
# command (Docker Desktop, brew services, another terminal) counts as another program.
pids=$(listeners)
if [ -n "$pids" ]; then
    saved=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$saved" ]; then
        for p in $pids; do
            if descends_from "$p" "$saved"; then
                echo "Already running on port $APP_PORT. Opening $APP_URL"
                open "$APP_URL"
                exit 0
            fi
        done
    fi
    echo "Port $APP_PORT is in use by another program:"
    for p in $pids; do
        printf '  PID %s: %s\n' "$p" "$(ps -o command= -p "$p" 2>/dev/null)"
    done
    printf 'Stop it and start %s? [y/N] ' "$APP_NAME"
    read -r answer || answer=""
    case $answer in
        [Yy]*) ;;
        *) echo "Left it running; nothing started."; exit 1 ;;
    esac
    # Stop only what was listening both when asked and now, so a PID that changed hands
    # while the question was open is never signalled.
    for p in $(listeners); do
        for asked in $pids; do
            if [ "$p" = "$asked" ]; then kill -TERM "$p" 2>/dev/null; fi
        done
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(listeners)" ] && break
        sleep 0.5
    done
    if [ -n "$(listeners)" ]; then
        echo "Port $APP_PORT is still in use; not starting."
        exit 1
    fi
fi

cd -- "${APP_WORKDIR:-$HOME}" || { echo "Can't open the folder ${APP_WORKDIR:-$HOME}"; exit 1; }

if [ -n "$APP_VENV" ]; then
    if [ -f "$APP_VENV/bin/activate" ]; then
        . "$APP_VENV/bin/activate"
    else
        echo "Note: no virtual environment at $APP_VENV; continuing without it."
    fi
fi

# The install command runs on the first launch, and again whenever it changes.
if [ -n "$APP_INSTALL_CMD" ] && [ "$(cat "$installed" 2>/dev/null)" != "$APP_INSTALL_CMD" ]; then
    echo "First run: $APP_INSTALL_CMD"
    if ! /bin/zsh -c "$APP_INSTALL_CMD"; then
        echo "The install command failed; it will run again next time."
        exit 1
    fi
    mkdir -p "$state" && printf '%s' "$APP_INSTALL_CMD" > "$installed"
fi

echo "Starting: $APP_START_CMD"
/bin/zsh -c "$APP_START_CMD" &
server=$!
started=$server
mkdir -p "$state" && echo "$started" > "$pidfile"

# $server is cleared once it has been waited for, so a reused PID is never signalled.
cleanup() {
    trap - EXIT HUP INT TERM
    if [ -n "$server" ]; then stop_tree "$server"; fi
    if [ "$(cat "$pidfile" 2>/dev/null)" = "$started" ]; then rm -f "$pidfile"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Wait for the server to answer. A start command that exits non-zero is a failure; one
# that exits 0 may have started the server in the background, so keep waiting for it.
deadline=$(($(date +%s) + APP_WAIT_SECONDS))
answered=""
while :; do
    # Liveness only: any HTTP answer counts, and a local self-signed certificate is fine.
    if curl -q -s -k -o /dev/null --globoff --noproxy '*' --max-time 2 "$APP_URL"; then
        answered=1
        break
    fi
    if [ -n "$server" ] && ! kill -0 "$server" 2>/dev/null; then
        wait "$server"
        status=$?
        server=""
        if [ "$status" -ne 0 ]; then
            echo "The start command failed (exit status $status)."
            exit "$status"
        fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.5
done

[ -n "$answered" ] || echo "No answer from $APP_URL after $APP_WAIT_SECONDS seconds; opening it anyway."
open "$APP_URL"

if [ -n "$server" ] && kill -0 "$server" 2>/dev/null; then
    echo "Running. Close this window or press Ctrl-C to stop $APP_NAME."
    wait "$server"
    status=$?
    server=""
    echo "The server stopped (exit status $status)."
    exit "$status"
fi
