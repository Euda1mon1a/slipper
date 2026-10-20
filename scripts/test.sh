#!/bin/bash
# End-to-end checks for Slipper (bash 3.2). Everything is built inside a new scratch folder;
# HOME and TMPDIR point into it, and stand-ins for `open` and `osascript` record what would
# have happened, so nothing reaches Terminal, the browser, the Dock or the real home folder.
#
# Usage: scripts/test.sh <new scratch dir>
set -u
[ $# -eq 1 ] || { echo "usage: $0 <new scratch dir>"; exit 2; }
[ -e "$1" ] && { echo "$1 already exists; give a folder that doesn't exist yet"; exit 2; }
mkdir -p "$1" || exit 2
R=$(cd "$1" && pwd -P)
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL="$REPO/slipper"

# Fixtures reach scratch paths through these variables, never by pasting $R into quotes.
export HOME="$R/home" TMPDIR="$R/tmp" OPEN_LOG="$R/open.log" OSA_LOG="$R/osascript.log"
export CANARY="$R/canary" ARGS_FILE="$R/args.txt" INSTALL_LOG="$R/install.log"
mkdir -p "$HOME" "$TMPDIR" "$CANARY" "$R/bin" "$R/work"
cat > "$R/bin/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$OPEN_LOG"
EOF
cat > "$R/bin/osascript" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$OSA_LOG"
EOF
chmod +x "$R/bin/open" "$R/bin/osascript"
export PATH="$R/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CDPATH
cd "$R/work" || exit 2

# 64x64 solid-colour PNG for the icon checks.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsEtiTiMaywi+hcEKLNXzWgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgt9cOE8/JmApAAAAABJRU5ErkJggg==' | base64 -D > "$R/icon.png"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
check() {
    local what=$1
    shift
    if "$@"; then ok "$what"; else bad "$what"; fi
}
plist_get() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
conf_get() { (. "$1/Contents/Resources/slipper.conf" && eval "printf '%s' \"\$$2\""); }
entries() { ls -A "$1" | wc -l | tr -d ' '; }
no_pwned() { [ -z "$(find "$R" -name 'PWNED*' 2>/dev/null)" ]; }
tree_sum() { (cd "$1" && find . -type f -exec shasum {} + | sort | shasum); }
free_port() {
    local p
    while :; do
        p=$((40000 + RANDOM % 20000))
        [ -z "$(lsof -nP -iTCP:$p -sTCP:LISTEN -t 2>/dev/null)" ] && { echo "$p"; return; }
    done
}
wait_for() { # seconds command...
    local n=$(($1 * 10))
    shift
    while [ "$n" -gt 0 ]; do
        "$@" && return 0
        sleep 0.1
        n=$((n - 1))
    done
    return 1
}
listening() { [ -n "$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null)" ]; }
not_listening() { ! listening "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }
build() { "$TOOL" "$@" > "$R/build.log" 2>&1; }
# Foreground only: in the background, a function runs in a subshell whose PID isn't the launcher's.
launch() { bash "$1/Contents/Resources/launcher.command"; }
STATE="$HOME/Library/Application Support/Slipper"
SHIMS="$HOME/Library/Caches/Slipper"
pidfiles() { ls -A "$STATE" 2>/dev/null | grep -c "^$1-[0-9a-f]*\.pid\$"; }
no_pidfile() { [ "$(pidfiles "$1")" = 0 ]; }
# Same list as the tool: spelled out, so the check is the same in every locale.
plain() { case $1 in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-]*) return 1 ;; esac; }

echo "== version and help"
check "--version prints 0.1.0" [ "$("$TOOL" --version)" = "slipper 0.1.0" ]
check "--help exits 0 and shows usage" sh -c '"$1" --help | grep -q "^Usage: slipper"' _ "$TOOL"

echo "== bad input is refused and creates nothing"
mkdir "$R/refuse"
refuses() { # description args...
    local what=$1
    shift
    if "$TOOL" "$@" > "$R/refuse.log" 2>&1; then
        bad "$what (exit 0)"
    elif [ "$(entries "$R/refuse")" != 0 ]; then
        bad "$what (left files behind)"
    else
        ok "$what"
    fi
}
O="$R/refuse/X.app"
refuses "missing --name" --port 3000 --start-cmd true --output "$O"
refuses "missing --start-cmd" --name X --port 3000 --output "$O"
refuses "port 0" --name X --port 0 --start-cmd true --output "$O"
refuses "port 70000" --name X --port 70000 --start-cmd true --output "$O"
refuses "port abc" --name X --port abc --start-cmd true --output "$O"
refuses "--wait 0" --name X --port 3000 --start-cmd true --wait 0 --output "$O"
refuses "ftp URL" --name X --port 3000 --start-cmd true --url ftp://x --output "$O"
refuses "URL with a space" --name X --port 3000 --start-cmd true --url "http://x/a b" --output "$O"
refuses "name with no letters or digits" --name '!!!' --port 3000 --start-cmd true --output "$O"
refuses "name of only spaces" --name '   ' --port 3000 --start-cmd true --output "$O"
refuses "name with a newline" --name "$(printf 'a\nb')" --port 3000 --start-cmd true --output "$O"
refuses "name that isn't valid UTF-8" --name "$(printf 'Caf\351')" --port 3000 --start-cmd true --output "$O"
refuses "missing icon file" --name X --port 3000 --start-cmd true --icon "$R/nope.png" --output "$O"
refuses "icon that isn't an image" --name X --port 3000 --start-cmd true --icon "$REPO/README.md" --output "$O"
refuses "output not ending in .app" --name X --port 3000 --start-cmd true --output "$R/refuse/X"
refuses "output with nothing before .app" --name X --port 3000 --start-cmd true --output "$R/refuse/.app"
refuses "output folder missing" --name X --port 3000 --start-cmd true --output "$R/refuse/missing/X.app"
refuses "unknown option" --name X --port 3000 --start-cmd true --frobnicate --output "$O"
refuses "option without a value" --name X --port 3000 --start-cmd
check "no stray files from the refusals" no_pwned

echo "== an app with a hostile name, paths and URL"
# Canaries: if any of these ran, a PWNED file would appear. The balanced a'...'b form fires
# on a quoting regression that a plain $(...) would not.
NAME="Bob's \"App\" \$(touch \"\$CANARY/PWNED1\") \`touch \"\$CANARY/PWNED2\"\` & <x> a'\$(touch \"\$CANARY/PWNED9\")'b !!"
# Folder-name canaries are relative (a slash would make nested folders); the tool and the
# launcher only ever run with a working folder inside the scratch folder.
OUTDIR="$R/out dir \$(touch PWNED3) 'q' !x"$'\n'"line two"
WORKDIR="$R/work dir \$(touch PWNED6) \"w\" a'\$(touch PWNED11)'b"
VENV="$R/venv dir \`touch PWNED7\`"
mkdir -p "$OUTDIR" "$WORKDIR" "$VENV/bin"
echo 'export VENV_MARK=venv-ok' > "$VENV/bin/activate"
PORT=$(free_port)
URL="http://localhost:$PORT/?a=1&b='x'&c=a'\$(touch\${IFS}PWNED8)'b#frag"
START_CMD=$(cat <<'EOF'
printf '%s\n' "it's" '$(touch "$CANARY/PWNED4")' '`touch "$CANARY/PWNED5"`' a'$(touch "$CANARY/PWNED10")'b "$VENV_MARK" "$PWD" > "$ARGS_FILE"
EOF
)
INSTALL_CMD='echo installed >> "$INSTALL_LOG"'
APP="$OUTDIR/Bob's App.app"
ls -A "$HOME" > "$R/home.before"
build --name "$NAME" --icon "$R/icon.png" --port "$PORT" --url "$URL" --wait 1 \
    --workdir "$WORKDIR" --venv "$VENV" --install-cmd "$INSTALL_CMD" \
    --start-cmd "$START_CMD" --output "$APP"
check "build succeeds" [ $? = 0 ]
check "Info.plist passes plutil -lint" plutil -lint -s "$APP/Contents/Info.plist"
check "CFBundleName is the name exactly" [ "$(plist_get "$APP" CFBundleName)" = "$NAME" ]
ID=$(plist_get "$APP" SlipperID)
check "bundle ID is local.slipper.<random ID>" \
    sh -c 'printf "%s" "$1" | grep -Eq "^local\.slipper\.[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"' _ "$(plist_get "$APP" CFBundleIdentifier)"
check "slipper.conf carries the same ID" [ "$(conf_get "$APP" APP_ID)" = "$ID" ]
EXE="$APP/Contents/MacOS/$(plist_get "$APP" CFBundleExecutable)"
check "bundle executable exists and is executable" [ -x "$EXE" ]
check "icon is a valid .icns" iconutil -c iconset "$APP/Contents/Resources/AppIcon.icns" -o "$R/roundtrip.iconset"
check "icns holds a 1024 px image" [ -f "$R/roundtrip.iconset/icon_512x512@2x.png" ]
check "Info.plist names the icon" [ "$(plist_get "$APP" CFBundleIconFile)" = AppIcon ]
check "output folder holds only the app" [ "$(entries "$OUTDIR")" = 1 ]
check "the build wrote nothing to HOME" sh -c 'ls -A "$1" | cmp -s - "$2"' _ "$HOME" "$R/home.before"
check "nothing in the name or paths ran" no_pwned

# Every value in this app has balanced quotes, so a quoting regression runs the canary
# instead of stopping at a parse error.
CANARY_NAME="a'\$(touch \"\$CANARY/PWNED12\")'b"
build --name "$CANARY_NAME" --port 3000 --start-cmd true --output "$R/Canary.app"
check "a balanced a'\$(...)'b name reads back from slipper.conf exactly" [ "$(conf_get "$R/Canary.app" APP_NAME)" = "$CANARY_NAME" ]
check "and reading it ran nothing" no_pwned

echo "== the app hands Terminal a plain shim path, and the shim finds the launcher"
: > "$OPEN_LOG"
"$EXE"
check "the bundle executable exits 0" [ $? = 0 ]
check "it runs open -a Terminal <shim>" \
    sh -c '[ "$(sed -n 1p "$1")" = -a ] && [ "$(sed -n 2p "$1")" = Terminal ] && [ "$(wc -l < "$1" | tr -d " ")" = 3 ]' _ "$OPEN_LOG"
SHIM=$(sed -n 3p "$OPEN_LOG")
shim_place() { case $1 in "$SHIMS/$ID".????????/launch.command) return 0 ;; esac; return 1; }
check "the shim is a one-time file under ~/Library/Caches/Slipper/<ID>.<random>/" shim_place "$SHIM"
check "the shim path uses only ASCII letters, digits and . _ / -" plain "$SHIM"
check "the shim is private (mode 700)" [ "$(stat -f %Lp "$SHIM")" = 700 ]
check "one launch, one shim folder" [ "$(entries "$SHIMS")" = 1 ]
: > "$OPEN_LOG"
# What Terminal does: type the path and "; exit;" into a shell.
/bin/zsh -c "$SHIM; exit;" < /dev/null > "$R/launch1.log" 2>&1
check "the shim runs the launcher, which exits 0" [ $? = 0 ]
check "the shim deleted itself and its folder" [ "$(entries "$SHIMS")" = 0 ]
{
    cat <<'EOF'
it's
$(touch "$CANARY/PWNED4")
`touch "$CANARY/PWNED5"`
a$(touch "$CANARY/PWNED10")b
venv-ok
EOF
    printf '%s\n' "$WORKDIR"
} > "$R/args.expected"
check "start command ran in the work dir, venv active, arguments intact" cmp -s "$ARGS_FILE" "$R/args.expected"
check "browser opened at the exact URL" [ "$(cat "$OPEN_LOG")" = "$URL" ]
check "install command ran once" [ "$(cat "$INSTALL_LOG")" = installed ]
: > "$OPEN_LOG"
"$EXE"
SHIM2=$(sed -n 3p "$OPEN_LOG")
check "each launch gets its own shim" sh -c '[ -n "$1" ] && [ "$1" != "$2" ] && [ -f "$1" ]' _ "$SHIM2" "$SHIM"
/bin/zsh -c "$SHIM2; exit;" < /dev/null > "$R/launch2.log" 2>&1
check "a second launch works" [ $? = 0 ]
check "and does not rerun the install command" [ "$(wc -l < "$INSTALL_LOG" | tr -d ' ')" = 1 ]
check "the install record exists for this copy" [ -n "$(ls -A "$STATE" | grep "^$ID-[0-9a-f]*\.installed\$")" ]
check "pidfile removed after the server exits" no_pidfile "$ID"
check "nothing in the commands ran outside its quotes" no_pwned

echo "== a failing start command stops there"
build --name Fails --port "$(free_port)" --start-cmd 'exit 3' --wait 5 --output "$R/Fails.app"
: > "$OPEN_LOG"
launch "$R/Fails.app" < /dev/null > "$R/fail.log" 2>&1
check "launcher exits with the command's status (3)" [ $? = 3 ]
check "no browser opened" [ ! -s "$OPEN_LOG" ]

echo "== a server process is forgotten once it has been waited for"
# Once waited for, its PID can be reused by an unrelated process, so the exit cleanup must
# not signal it. A stand-in pgrep logs every stop_tree call the cleanup makes.
mkdir -p "$R/pgrep-log-bin"
cat > "$R/pgrep-log-bin/pgrep" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PGREP_LOG"
exec /usr/bin/pgrep "$@"
STUB
chmod +x "$R/pgrep-log-bin/pgrep"
export PGREP_LOG="$R/pgrep.log"
P6=$(free_port)
build --name Quiet --port "$P6" --start-cmd true --wait 3 --output "$R/Quiet.app"
: > "$OPEN_LOG"
: > "$PGREP_LOG"
PATH="$R/pgrep-log-bin:$PATH" launch "$R/Quiet.app" < /dev/null > "$R/quiet.log" 2>&1
check "a start command that exits 0 without answering: the launcher waits, then exits 0" \
    sh -c '[ $1 = 0 ] && grep -q "No answer from" "$2"' _ $? "$R/quiet.log"
check "and opens the URL anyway" [ "$(cat "$OPEN_LOG")" = "http://localhost:$P6" ]
check "and its exit cleanup leaves the reaped PID alone" [ ! -s "$PGREP_LOG" ]
build --name Brief --port "$(free_port)" --start-cmd 'sleep 2' --wait 1 --output "$R/Brief.app"
: > "$PGREP_LOG"
PATH="$R/pgrep-log-bin:$PATH" launch "$R/Brief.app" < /dev/null > "$R/brief.log" 2>&1
check "a server that stops on its own: the launcher reports it" sh -c '[ $1 = 0 ] && grep -q "The server stopped" "$2"' _ $? "$R/brief.log"
check "and its exit cleanup leaves the reaped PID alone, too" [ ! -s "$PGREP_LOG" ]

echo "== a home folder path Terminal can't be given"
mkdir -p "$R/a b"
: > "$OPEN_LOG"
: > "$OSA_LOG"
HOME="$R/a b" "$EXE" > "$R/badhome.log" 2>&1
check "the app refuses (exit 1)" [ $? = 1 ]
check "and says why in an alert" grep -q "home folder's path has spaces" "$OSA_LOG"
check "without calling open" [ ! -s "$OPEN_LOG" ]
check "or writing a shim" [ -z "$(ls -A "$R/a b")" ]
# In a UTF-8 locale, bash ranges like [A-Za-z] also match letters such as ö; the tool's
# spelled-out list must still refuse them.
mkdir -p "$R/hö"
: > "$OSA_LOG"
LC_ALL=en_US.UTF-8 HOME="$R/hö" "$EXE" > "$R/badhome2.log" 2>&1
check "a non-ASCII home path is refused too, in a UTF-8 locale" sh -c '[ $1 = 1 ] && grep -q "home folder" "$2" && [ ! -s "$3" ]' _ $? "$OSA_LOG" "$OPEN_LOG"
: > "$OSA_LOG"

echo "== a duplicated app keeps its own state"
export DUP_LOG="$R/dup.log"
build --name Dup --port "$(free_port)" --start-cmd true --wait 1 --install-cmd 'echo run >> "$DUP_LOG"' --output "$R/Dup.app"
launch "$R/Dup.app" < /dev/null > /dev/null 2>&1
cp -R "$R/Dup.app" "$R/Dup copy.app"
check "the copy shares the original's ID" [ "$(plist_get "$R/Dup copy.app" SlipperID)" = "$(plist_get "$R/Dup.app" SlipperID)" ]
launch "$R/Dup copy.app" < /dev/null > /dev/null 2>&1
check "the copy runs its own install" [ "$(wc -l < "$DUP_LOG" | tr -d ' ')" = 2 ]
launch "$R/Dup.app" < /dev/null > /dev/null 2>&1
check "and the original doesn't run it again" [ "$(wc -l < "$DUP_LOG" | tr -d ' ')" = 2 ]

echo "== a running server is reused, and stopped by TERM, HUP and INT"
P2=$(free_port)
build --name Server --port "$P2" --start-cmd "exec nc -lk 127.0.0.1 $P2" --wait 1 --output "$R/Server.app"
SID=$(plist_get "$R/Server.app" SlipperID)
running() { grep -q '^Running\.' "$1"; }
bash "$R/Server.app/Contents/Resources/launcher.command" < /dev/null > "$R/server1.log" 2>&1 &
L=$!
check "server comes up and the launcher waits on it" wait_for 10 running "$R/server1.log"
check "it is listening" listening "$P2"
check "and has a pidfile" [ "$(pidfiles "$SID")" = 1 ]
launch "$R/Server.app" < /dev/null > "$R/server2.log" 2>&1
check "second launch reuses the running server" sh -c '[ $1 = 0 ] && grep -q "Already running" "$2"' _ $? "$R/server2.log"
kill -TERM "$L"
wait "$L"
check "TERM: launcher exits 143" [ $? = 143 ]
check "TERM: the server stops" wait_for 5 not_listening "$P2"
check "TERM: the pidfile is removed" no_pidfile "$SID"

bash "$R/Server.app/Contents/Resources/launcher.command" < /dev/null > "$R/server3.log" 2>&1 &
L=$!
check "relaunch comes up" wait_for 10 running "$R/server3.log"
kill -HUP "$L"
wait "$L"
check "HUP (window closed): launcher exits 129" [ $? = 129 ]
check "HUP: the server stops" wait_for 5 not_listening "$P2"

# Background jobs of a script ignore INT unless job control is on.
set -m
bash "$R/Server.app/Contents/Resources/launcher.command" < /dev/null > "$R/server4.log" 2>&1 &
L=$!
set +m
check "relaunch with job control comes up" wait_for 10 running "$R/server4.log"
kill -INT "$L"
wait "$L"
check "INT (Ctrl-C): launcher exits 130" [ $? = 130 ]
check "INT: the server stops" wait_for 5 not_listening "$P2"
check "INT: the pidfile is removed" no_pidfile "$SID"

echo "== another program on the port is left alone unless the user says yes"
P3=$(free_port)
nc -lk 127.0.0.1 "$P3" > /dev/null 2>&1 &
NC=$!
disown "$NC" # no job notice when the launcher stops it
check "the other program is listening" wait_for 5 listening "$P3"
build --name Busy --port "$P3" --start-cmd true --wait 1 --output "$R/Busy.app"
echo n | launch "$R/Busy.app" > "$R/busy-n.log" 2>&1
check "answering no exits 1" [ $? = 1 ]
check "and leaves the other program running" alive "$NC"
echo y | launch "$R/Busy.app" > "$R/busy-y.log" 2>&1
check "answering yes starts the app" [ $? = 0 ]
check "after stopping the other program" wait_for 5 not_listening "$P3"
kill "$NC" 2>/dev/null

echo "== the launcher never force-kills"
check "no KILL signal anywhere in the code" \
    sh -c '! grep -n -E "kill +-(9|KILL|s +KILL)|SIGKILL" "$@"' _ "$TOOL" "$REPO/templates/launcher.command" "$REPO/templates/open-in-terminal"
P4=$(free_port)
(trap '' TERM; exec nc -lk 127.0.0.1 "$P4") > /dev/null 2>&1 &
STUBBORN=$!
disown "$STUBBORN"
check "a program that ignores TERM is listening" wait_for 5 listening "$P4"
build --name Stubborn --port "$P4" --start-cmd true --wait 1 --output "$R/Stubborn.app"
echo y | launch "$R/Stubborn.app" > "$R/stubborn.log" 2>&1
check "a program that ignores TERM: launcher gives up (exit 1)" sh -c '[ $1 = 1 ] && grep -q "still in use" "$2"' _ $? "$R/stubborn.log"
check "and the program is still alive (no KILL sent)" alive "$STUBBORN"
kill -KILL "$STUBBORN" 2>/dev/null

echo "== a PID that changes hands during the question is not signalled"
P5=$(free_port)
# FIRST listens until it gets USR1, then closes its socket but keeps running: the launcher
# must not signal a PID that is no longer listening when the user answers.
/usr/bin/perl -MIO::Socket::INET -e '
    my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => $ARGV[0], ReuseAddr => 1) or die;
    $SIG{USR1} = sub { close $s };
    sleep 1 while 1;' "$P5" > /dev/null 2>&1 &
FIRST=$!
disown "$FIRST"
check "the first program is listening" wait_for 5 listening "$P5"
build --name Swap --port "$P5" --start-cmd true --wait 1 --output "$R/Swap.app"
mkfifo "$R/answer.fifo"
bash "$R/Swap.app/Contents/Resources/launcher.command" < "$R/answer.fifo" > "$R/swap.log" 2>&1 &
L=$!
exec 3<> "$R/answer.fifo" # read-write: never blocks, even if the launcher failed to start
asked() { grep -q 'Stop it and start' "$R/swap.log"; }
check "the launcher asks" wait_for 10 asked
kill -USR1 "$FIRST"
check "the first program stops listening" wait_for 5 not_listening "$P5"
nc -lk 127.0.0.1 "$P5" > /dev/null 2>&1 &
SECOND=$!
disown "$SECOND"
check "a different program now holds the port" wait_for 5 listening "$P5"
echo y >&3
exec 3>&-
wait "$L"
check "answering yes then leaves the new program alone (exit 1)" sh -c '[ $1 = 1 ] && grep -q "still in use" "$2"' _ $? "$R/swap.log"
check "and it is still alive" alive "$SECOND"
check "the first program, no longer listening, was not signalled either" alive "$FIRST"
kill "$SECOND" "$FIRST" 2>/dev/null

echo "== existing apps"
mkdir -p "$R/apps/Foreign.app/Contents"
plutil -create xml1 "$R/apps/Foreign.app/Contents/Info.plist"
plutil -insert CFBundleName -string Foreign "$R/apps/Foreign.app/Contents/Info.plist"
echo keep > "$R/apps/Foreign.app/Contents/data"
SUM=$(tree_sum "$R/apps/Foreign.app")
build --name Foreign --port 3000 --start-cmd true --output "$R/apps/Foreign.app"
check "refuses to replace an app it didn't create" sh -c '[ $1 != 0 ] && grep -q "not created by Slipper" "$2"' _ $? "$R/build.log"
check "the other app is untouched" [ "$(tree_sum "$R/apps/Foreign.app")" = "$SUM" ]
build --name Foreign --port 3000 --start-cmd true --output "$R/apps/Foreign.app" --force
check "--force replaces it" [ "$(plist_get "$R/apps/Foreign.app" SlipperVersion)" = 0.1.0 ]
kept_unchanged() {
    local kept
    kept=$(ls -d "$R"/apps/Foreign.app.replaced-* 2>/dev/null | head -n 1)
    [ -n "$kept" ] && [ "$(tree_sum "$kept")" = "$SUM" ]
}
check "and keeps the old one beside it, unchanged" kept_unchanged
FID=$(plist_get "$R/apps/Foreign.app" SlipperID)
build --name Foreign --port 4000 --start-cmd true --output "$R/apps/Foreign.app"
check "re-running replaces its own app without --force" grep -q "^APP_PORT='4000'$" "$R/apps/Foreign.app/Contents/Resources/slipper.conf"
check "and keeps the app's ID" [ "$(plist_get "$R/apps/Foreign.app" SlipperID)" = "$FID" ]
check "no staging folders left behind" [ -z "$(ls -A "$R/apps" | grep '^\.slipper')" ]
check "apps folder holds only the app and the kept copy" [ "$(entries "$R/apps")" = 2 ]
mkdir "$R/elsewhere"
ln -s "$R/elsewhere" "$R/apps/Link.app"
build --name Link --port 3000 --start-cmd true --output "$R/apps/Link.app" --force
check "refuses a symlinked target, even with --force" sh -c '[ $1 != 0 ] && [ -z "$(ls -A "$2")" ]' _ $? "$R/elsewhere"

echo "== IDs never collide"
mkdir -p "$R/ids/a" "$R/ids/b"
build --name To-Do --port 3000 --start-cmd true --output "$R/ids/a/To-Do.app"
build --name todo --port 3000 --start-cmd true --output "$R/ids/a/todo.app"
build --name todo --port 3000 --start-cmd true --output "$R/ids/b/todo.app"
three_ids() {
    local x y z
    x=$(plist_get "$R/ids/a/To-Do.app" CFBundleIdentifier)
    y=$(plist_get "$R/ids/a/todo.app" CFBundleIdentifier)
    z=$(plist_get "$R/ids/b/todo.app" CFBundleIdentifier)
    [ -n "$x" ] && [ -n "$y" ] && [ -n "$z" ] && [ "$x" != "$y" ] && [ "$y" != "$z" ] && [ "$x" != "$z" ]
}
check "To-Do, todo, and todo in another folder get three bundle IDs" three_ids

echo "== locked files and failures leave the previous app in place"
mkdir -p "$R/keep"
build --name Keep --port 3000 --start-cmd true --output "$R/keep/Keep.app"
echo locked > "$R/keep/Keep.app/Contents/Resources/locked.txt"
chflags uchg "$R/keep/Keep.app/Contents/Resources/locked.txt"
SUM=$(tree_sum "$R/keep/Keep.app")
build --name Keep --port 4000 --start-cmd true --output "$R/keep/Keep.app"
check "refuses to replace an app with a Finder-locked file" sh -c '[ $1 != 0 ] && grep -q "locked files" "$2"' _ $? "$R/build.log"
check "the app is untouched and nothing is staged" sh -c '[ "$1" = "$2" ] && [ "$(ls -A "$3")" = Keep.app ]' _ \
    "$(tree_sum "$R/keep/Keep.app")" "$SUM" "$R/keep"
chflags nouchg "$R/keep/Keep.app/Contents/Resources/locked.txt"

mkdir -p "$R/ro"
build --name RO --port 3000 --start-cmd true --output "$R/ro/RO.app"
chmod 555 "$R/ro/RO.app/Contents/Resources"
build --name RO --port 4000 --start-cmd true --output "$R/ro/RO.app"
check "replacing an app with a read-only folder inside works" sh -c '[ $1 = 0 ] && grep -q "APP_PORT=.4000.$" "$2"' _ $? "$R/ro/RO.app/Contents/Resources/slipper.conf"
check "and leaves no staging folder behind" [ "$(ls -A "$R/ro")" = RO.app ]

# A stand-in mv that fails only when moving the new Contents into place.
mkdir -p "$R/mvfail"
cat > "$R/mvfail/mv" <<'EOF'
#!/bin/bash
for arg; do
    case $arg in */new.app/Contents) echo "mv: injected failure" >&2; exit 1 ;; esac
done
exec /bin/mv "$@"
EOF
chmod +x "$R/mvfail/mv"
SUM=$(tree_sum "$R/keep/Keep.app")
PATH="$R/mvfail:$PATH" "$TOOL" --name Keep --port 5000 --start-cmd true --output "$R/keep/Keep.app" > "$R/build.log" 2>&1
check "a failure mid-replace exits non-zero" sh -c '[ $1 != 0 ] && grep -q "put the previous app back" "$2"' _ $? "$R/build.log"
check "and puts the previous app back unchanged, with nothing staged" sh -c '[ "$1" = "$2" ] && [ "$(ls -A "$3")" = Keep.app ]' _ \
    "$(tree_sum "$R/keep/Keep.app")" "$SUM" "$R/keep"
mkdir -p "$R/keep2/Other.app/Contents"
echo other > "$R/keep2/Other.app/Contents/data"
SUM=$(tree_sum "$R/keep2/Other.app")
PATH="$R/mvfail:$PATH" "$TOOL" --name Other --port 5000 --start-cmd true --output "$R/keep2/Other.app" --force > "$R/build.log" 2>&1
check "the same for --force: the other app is back, no renamed copy left" sh -c '[ $1 != 0 ] && [ "$2" = "$3" ] && [ "$(ls -A "$4")" = Other.app ]' _ \
    $? "$(tree_sum "$R/keep2/Other.app")" "$SUM" "$R/keep2"

echo "== concurrent runs never nest one app inside another"
mkdir -p "$R/race"
build --name Race --port 3000 --start-cmd true --output "$R/race/Race.app"
for i in 1 2 3 4 5 6 7 8 9 10; do
    "$TOOL" --name Race --port 3000 --start-cmd true --output "$R/race/Race.app" > "$R/race-$i.log" 2>&1 &
done
wait
check "one valid app results" plutil -lint -s "$R/race/Race.app/Contents/Info.plist"
check "with no app nested inside it" [ -z "$(find "$R/race/Race.app" -mindepth 1 -name '*.app')" ]
check "and no Contents/Contents anywhere" [ -z "$(find "$R/race" -path '*/Contents/Contents')" ]
check "and nothing else left in the folder (no staging, lock or kept copies)" [ "$(ls -A "$R/race")" = Race.app ]
lock_or_ok() {
    local f
    for f in "$R"/race-*.log; do
        grep -q '^Created ' "$f" || grep -q 'another Slipper run is working on' "$f" || return 1
    done
}
check "every run either finished or was turned away by the lock" lock_or_ok

echo "== the per-target lock"
mkdir -p "$R/locked"
build --name Held --port 3000 --start-cmd true --output "$R/locked/Held.app"
LOCKDIR="$R/locked/.slipper-lock-$(printf '%s' Held.app | shasum -a 256 | cut -c1-16)"
check "a finished run leaves no lock behind" [ ! -e "$LOCKDIR" ]
SUM=$(tree_sum "$R/locked/Held.app")
mkdir "$LOCKDIR"
echo $$ > "$LOCKDIR/owner"
build --name Held --port 4000 --start-cmd true --output "$R/locked/Held.app"
check "a lock held by a live run turns this one away" sh -c '[ $1 != 0 ] && grep -q "another Slipper run is working on" "$2"' _ $? "$R/build.log"
echo 999999 > "$LOCKDIR/owner"
build --name Held --port 4000 --start-cmd true --output "$R/locked/Held.app"
check "a lock left by a dead run says how to clear it" sh -c '[ $1 != 0 ] && grep -q "stopped without cleaning up. Remove the folder" "$2"' _ $? "$R/build.log"
check "and the app is untouched either way" [ "$(tree_sum "$R/locked/Held.app")" = "$SUM" ]
check "and the other run's lock is left in place" [ "$(cat "$LOCKDIR/owner")" = 999999 ]

echo "== paths"
mkdir -p "$HOME/Desktop" "$R/folder"
build --name "Default Place" --port 3000 --start-cmd true
check "default is ~/Desktop/<name>.app" [ -d "$HOME/Desktop/Default Place.app" ]
build --name "In Folder" --port 3000 --start-cmd true --output "$R/folder"
check "a folder as --output puts <name>.app inside it" [ -d "$R/folder/In Folder.app" ]
build --name "-dash name" --port 3000 --start-cmd true --output "$R/folder/Dash.app"
check "a name starting with a dash is kept as typed" [ "$(plist_get "$R/folder/Dash.app" CFBundleName)" = "-dash name" ]
build --name D --port 3000 --start-cmd true --output -d.app
check "a relative --output starting with a dash works" [ -d "$R/work/-d.app/Contents" ]
mkdir -p "$R/cdp/sub" "$R/work/sub"
CDPATH="$R/cdp" "$TOOL" --name C --port 3000 --start-cmd true --output sub/C.app > "$R/build.log" 2>&1
check "CDPATH is ignored" sh -c '[ -d "$1" ] && [ ! -e "$2" ]' _ "$R/work/sub/C.app" "$R/cdp/sub/C.app"
NLDIR="$R/ends with newline"$'\n'
mkdir "$NLDIR"
build --name Newline --port "$(free_port)" --wait 1 --workdir "$NLDIR" \
    --start-cmd 'printf "%s" "$PWD" > "$ARGS_FILE"' --output "$R/folder/Newline.app"
launch "$R/folder/Newline.app" < /dev/null > /dev/null 2>&1
check "a work dir whose name ends in a newline is kept exactly" sh -c 'printf "%s" "$1" | cmp -s - "$2"' _ "$NLDIR" "$ARGS_FILE"

echo "== text"
build --name "Café ☕" --port 3000 --start-cmd true --output "$R/folder/Cafe.app"
check "a UTF-8 name is kept exactly" [ "$(plist_get "$R/folder/Cafe.app" CFBundleName)" = "Café ☕" ]
RAW_CMD="echo $(printf 'caf\351') 'it'\''s'"$'\n\n'
build --name Bytes --port 3000 --start-cmd "$RAW_CMD" --output "$R/folder/Bytes.app"
(. "$R/folder/Bytes.app/Contents/Resources/slipper.conf" && printf '%s' "$APP_START_CMD") > "$R/bytes.got"
check "a command with invalid UTF-8 and trailing newlines round-trips byte for byte" \
    sh -c 'printf "%s" "$1" | cmp -s - "$2"' _ "$RAW_CMD" "$R/bytes.got"

echo "== works when installed the way Homebrew installs it"
mkdir -p "$R/cellar/bin" "$R/cellar/share/slipper" "$R/linked"
cp "$TOOL" "$R/cellar/bin/slipper"
cp -R "$REPO/templates" "$R/cellar/share/slipper/templates"
ln -s "$R/cellar/bin/slipper" "$R/linked/slipper"
"$R/linked/slipper" --name Brewed --port 3000 --start-cmd true --output "$R/folder" > /dev/null 2>&1
check "templates found through the bin symlink" [ -x "$R/folder/Brewed.app/Contents/Resources/launcher.command" ]
mkdir -p "$R/lonely"
cp "$TOOL" "$R/lonely/slipper"
SLIPPER_TEMPLATES="$REPO/templates" "$R/lonely/slipper" --name Env --port 3000 --start-cmd true --output "$R/folder" > /dev/null 2>&1
check "SLIPPER_TEMPLATES overrides the lookup" [ -d "$R/folder/Env.app" ]

echo "== nothing escaped the scratch folder"
check "no command injection anywhere" no_pwned
check "no failure alerts were raised" [ ! -s "$OSA_LOG" ]
check "TMPDIR left empty" [ -z "$(ls -A "$TMPDIR")" ]

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
