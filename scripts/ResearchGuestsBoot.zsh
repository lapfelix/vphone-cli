#!/bin/zsh
set -euo pipefail

# Developer workflow for a CFW-installed research VM on Apple's signed VRE host.
# The guest debugger action reproduces the existing, selected AVPBooter digest
# patch on this known Apple ROM; no host SIP or AMFI setting is changed.

script_dir=${0:a:h}
repo_root=${script_dir:h}
cli=${VPHONE_CLI:-"$repo_root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli"}
vrevm=/System/Library/SecurityResearch/usr/bin/vrevm
rom=/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin
expected_rom_hash=301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072

if (( $# != 4 && $# != 5 )); then
    print -u2 "usage: ${0:t} VPHONE_LIBRARY_ROOT VPHONE_MACHINE VREVM_DATADIR VREVM_NAME [--reuse-prepared]"
    exit 64
fi
library_root=$1
machine=$2
vrevm_datadir=$3
vrevm_name=$4
vrevm_config="$vrevm_datadir/$vrevm_name.vm/config.plist"
typeset -a reuse_args
reuse_args=()
if (( $# == 5 )); then
    [[ $5 == --reuse-prepared ]] || {
        print -u2 "Unknown option: $5 (expected --reuse-prepared)"
        exit 64
    }
    reuse_args=(--reuse-prepared)
fi

[[ -x $cli ]] || { print -u2 "vphone-cli is missing: $cli"; exit 1; }
[[ -x $vrevm ]] || { print -u2 "Apple's vrevm is missing: $vrevm"; exit 1; }
[[ -f $vrevm_config ]] || { print -u2 "Research Guest config is missing: $vrevm_config"; exit 1; }
[[ -f $rom ]] || { print -u2 "Apple's research AP ROM is missing: $rom"; exit 1; }

rom_hash=$(/usr/bin/openssl dgst -sha256 "$rom")
rom_hash=${rom_hash##* }
[[ $rom_hash == $expected_rom_hash ]] || {
    print -u2 "Unsupported research AP ROM ($rom_hash). Recheck the guest digest return site before using this workflow."
    exit 1
}

# The CLI checks the selected patch plan, installed ticket, VRE identity, and
# either the restore sources or nine saved IMG4s before starting the VM.
"$cli" vm research-upload --library-root "$library_root" "$machine" \
    --vrevm-config "$vrevm_config" --prepare-only "${reuse_args[@]}"

work_dir=$(mktemp -d /tmp/vphone-research-boot.XXXXXX)
vrevm_log="$work_dir/vrevm.log"
lldb_log="$work_dir/lldb.log"
lldb_commands="$work_dir/lldb.commands"
vrevm_pid=
lldb_pid=

cleanup() {
    stop_child "$lldb_pid"
    stop_child "$vrevm_pid"
    print "Research boot logs: $work_dir"
}

# `vrevm` may ignore SIGINT. Never wait indefinitely during cleanup, and never
# signal a PID that is no longer this script's child if it exited meanwhile.
stop_child() {
    local child_pid=$1
    [[ -n $child_pid ]] || return 0

    local parent_pid
    parent_pid=$(/bin/ps -p "$child_pid" -o ppid= 2>/dev/null) || return 0
    parent_pid=${parent_pid//[[:space:]]/}
    [[ $parent_pid == $$ ]] || return 0
    kill -TERM "$child_pid" 2>/dev/null || true

    for attempt in {1..20}; do
        parent_pid=$(/bin/ps -p "$child_pid" -o ppid= 2>/dev/null) || return 0
        parent_pid=${parent_pid//[[:space:]]/}
        [[ $parent_pid == $$ ]] || return 0
        sleep 0.25
    done

    parent_pid=$(/bin/ps -p "$child_pid" -o ppid= 2>/dev/null) || return 0
    parent_pid=${parent_pid//[[:space:]]/}
    [[ $parent_pid == $$ ]] && kill -KILL "$child_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$vrevm" run --datadir "$vrevm_datadir" --name "$vrevm_name" --noask --dfu > "$vrevm_log" 2>&1 &
vrevm_pid=$!

port=
for attempt in {1..100}; do
    port=$(/usr/bin/grep -oE '^GDB stub available at localhost:[0-9]+' "$vrevm_log" 2>/dev/null \
        | head -n 1 | cut -d: -f2 || true)
    [[ -n $port ]] && break
    if ! kill -0 "$vrevm_pid" 2>/dev/null; then
        print -u2 "vrevm exited before exposing its guest debugger."
        tail -n 30 "$vrevm_log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -n $port ]] || { print -u2 "Timed out waiting for vrevm's guest debugger."; exit 1; }

cat > "$lldb_commands" <<EOF
gdb-remote 127.0.0.1:$port
breakpoint set --hardware --address 0x102b88 --condition "\$x0 != 0"
breakpoint command add -o "register write x0 0" 1
breakpoint modify -G true 1
continue
EOF

lldb_bin=$(xcrun --find lldb)
"$lldb_bin" -b -s "$lldb_commands" > "$lldb_log" 2>&1 &
lldb_pid=$!
armed=false
for attempt in {1..200}; do
    if /usr/bin/grep -q '^[(]lldb[)] continue$' "$lldb_log" 2>/dev/null; then
        if ! /usr/bin/grep -Eq '^Breakpoint 1: address = 0x0*102b88$' "$lldb_log" \
            || /usr/bin/grep -Eiq '(^|[[:space:]])error:' "$lldb_log"; then
            print -u2 "LLDB did not arm the expected AP ROM breakpoint."
            tail -n 30 "$lldb_log" >&2
            exit 1
        fi
        armed=true
        break
    fi
    if ! kill -0 "$lldb_pid" 2>/dev/null; then
        print -u2 "LLDB exited before arming the guest breakpoint."
        tail -n 30 "$lldb_log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ $armed == true ]] || { print -u2 "Timed out arming the guest breakpoint."; exit 1; }

print "Guest debugger armed on Apple's verified research AP ROM. Uploading the boot chain..."
"$cli" vm research-upload --library-root "$library_root" "$machine" \
    --vrevm-config "$vrevm_config" "${reuse_args[@]}"

serial_line=$(/usr/bin/grep -m1 '^Console log available at: ' "$vrevm_log" || true)
serial_log=${serial_line#Console log available at: }
[[ -n $serial_log ]] || { print -u2 "vrevm did not report a serial log path."; exit 1; }

boot_complete=false
for attempt in {1..600}; do
    if [[ -f $serial_log ]] && /usr/bin/grep -q 'Early boot complete' "$serial_log"; then
        boot_complete=true
        break
    fi
    if [[ -f $serial_log ]] && /usr/bin/grep -Eq 'panic\(|Kernel panic' "$serial_log"; then
        print -u2 "The research guest panicked; inspect $serial_log"
        exit 1
    fi
    if ! kill -0 "$vrevm_pid" 2>/dev/null; then
        print -u2 "vrevm exited before iOS early boot completed; inspect $vrevm_log"
        exit 1
    fi
    sleep 0.5
done
[[ $boot_complete == true ]] || { print -u2 "Timed out waiting for iOS early boot; inspect $serial_log"; exit 1; }

print "iOS early boot completed. Research Guest is running. Serial log: $serial_log"
print "Press Ctrl-C to stop this VM. Controller logs: $work_dir"
wait "$vrevm_pid"
