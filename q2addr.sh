#!/system/bin/sh
# Manage the Quest 2 controller addresses baked into the module's libtrackingutils.
#
# The lib ships with three empty address slots. Whatever is written here gets the
# Jedi LED geometry (model 7001); everything else falls through to the stock
# per-type table. An empty slot is all zeroes, which no real controller matches,
# so an unconfigured lib behaves exactly like stock.
#
#   q2addr.sh show              what is currently configured
#   q2addr.sh detect            find Quest 2 controllers and configure them
#   q2addr.sh set <addr> [...]  write specific addresses (up to 3)
#   q2addr.sh clear             empty every slot

# Overridable so customize.sh can target the staged module before it is mounted.
MOD=${Q2CTRL_MOD:-/data/adb/modules/q2ctrl}
LIB=$MOD/system/lib64/libtrackingutils.so
CAL=/data/vendor/misc/sensors/controllercal

# File offsets of the three literals, and the ldr that proves this is our build.
SLOT0=130320   # 0x1fd10
SLOT1=130328   # 0x1fd18
SLOT2=130336   # 0x1fd20
MAGIC_OFF=130264   # 0x1fcd8, must be `ldr x8, LIT1` = c8 01 00 58
MAGIC=c8010058

# A Jedi's calibration blob carries a binary tail and runs ~8KB; an LCON's is
# ~2.4KB of plain JSON. The gap is structural, not marginal.
JEDI_MIN=4096

die() { echo "! $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root: su -c $0 $*"
[ -f "$LIB" ] || die "$LIB not found - is the q2ctrl module installed?"

got=$(dd if="$LIB" bs=1 skip=$MAGIC_OFF count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$got" = "$MAGIC" ] || die "$LIB is not the address-slot build (found $got, want $MAGIC)"

# Hex string -> raw bytes on stdout.
hex2bin() {
    if command -v xxd >/dev/null 2>&1; then
        echo "$1" | xxd -r -p
        return
    fi
    # No xxd: %b takes \0ooo octal escapes. The backslash comes from a variable
    # and the octal from its own assignment, because a literal backslash sitting
    # in front of an expansion inside double quotes is not something every shell
    # agrees on.
    bs='\'
    h=$1
    esc=
    while [ -n "$h" ]; do
        b=$(echo "$h" | cut -c1-2)
        h=$(echo "$h" | cut -c3-)
        o=$(printf '%03o' "$((0x$b))")
        esc="${esc}${bs}0${o}"
    done
    printf '%b' "$esc"
}

# 16 hex chars -> 8 raw little-endian bytes on stdout.
emit_le() {
    a=$1
    i=15
    rev=
    while [ "$i" -ge 1 ]; do
        rev="${rev}$(echo "$a" | cut -c${i}-$((i + 1)))"
        i=$((i - 2))
    done
    hex2bin "$rev"
}

emit_zero() { hex2bin 0000000000000000; }

# Read one slot back and undo the byte swap so it reads like an address.
read_slot() {
    raw=$(dd if="$LIB" bs=1 skip=$1 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
    out=
    i=15
    while [ "$i" -ge 1 ]; do
        out="${out}$(echo "$raw" | cut -c${i}-$((i + 1)))"
        i=$((i - 2))
    done
    echo "$out"
}

write_slot() {
    off=$1
    val=$2
    if [ -n "$val" ]; then
        emit_le "$val" | dd of="$LIB" bs=1 seek=$off count=8 conv=notrunc 2>/dev/null
    else
        emit_zero | dd of="$LIB" bs=1 seek=$off count=8 conv=notrunc 2>/dev/null
    fi || die "write to $LIB failed (in use?) - reboot and try again"
}

restart_tracking() {
    [ "${Q2CTRL_NORESTART:-0}" = "1" ] && { echo "- change applies at next boot"; return 0; }
    pid=$(pidof trackingservice 2>/dev/null)
    if [ -n "$pid" ]; then
        # init class late_start brings it straight back. `stop` can wedge it in
        # "stopping", so signal it instead.
        kill -9 $pid 2>/dev/null
        echo "- restarted trackingservice, models re-resolve on the next connect"
    else
        echo "- trackingservice not running, change applies at next boot"
    fi
}

show() {
    n=0
    for off in $SLOT0 $SLOT1 $SLOT2; do
        v=$(read_slot $off)
        case "$v" in
            0000000000000000) echo "  slot $n: (empty)" ;;
            *) echo "  slot $n: $v"; n_set=$((${n_set:-0} + 1)) ;;
        esac
        n=$((n + 1))
    done
    [ "${n_set:-0}" = "0" ] && echo "  nothing configured - Quest 2 controllers will use Quest 1 LED geometry"
    return 0
}

apply() {
    before="$(read_slot $SLOT0)$(read_slot $SLOT1)$(read_slot $SLOT2)"
    write_slot $SLOT0 "$1"
    write_slot $SLOT1 "$2"
    write_slot $SLOT2 "$3"
    after="$(read_slot $SLOT0)$(read_slot $SLOT1)$(read_slot $SLOT2)"
    echo "- wrote:"
    show
    # Bouncing trackingservice drops whatever is currently connected, so only pay
    # that cost when the addresses actually moved.
    if [ "$before" = "$after" ]; then
        echo "- already up to date, leaving trackingservice alone"
    else
        restart_tracking
    fi
}

case "${1:-show}" in
show)
    echo "configured Quest 2 controllers:"
    show
    ;;

clear)
    apply "" "" ""
    ;;

set)
    shift
    [ -n "$1" ] || die "usage: q2addr.sh set <addr> [addr] [addr]"
    for a in "$@"; do
        echo "$a" | grep -qE '^[0-9a-fA-F]{16}$' || die "'$a' is not a 16 hex digit address"
    done
    apply "$1" "$2" "$3"
    ;;

detect)
    [ -d "$CAL" ] || die "$CAL not found - pair a controller first"
    found=
    count=0
    for f in "$CAL"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        echo "$name" | grep -qE '^[0-9a-f]{16}$' || continue
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if [ "$size" -gt "$JEDI_MIN" ]; then
            echo "  $name  ${size}B  -> Quest 2"
            found="$found $name"
            count=$((count + 1))
        else
            echo "  $name  ${size}B  -> Quest 1"
        fi
    done
    [ "$count" = "0" ] && die "no Quest 2 controller found. Pair one first: $MOD/pair.sh 1"
    if [ "$count" -gt 3 ]; then
        die "found $count Quest 2 controllers but only 3 slots exist - use 'set' explicitly"
    fi
    echo
    apply $found
    ;;

*)
    echo "usage: q2addr.sh [show|detect|set <addr>...|clear]"
    exit 1
    ;;
esac
