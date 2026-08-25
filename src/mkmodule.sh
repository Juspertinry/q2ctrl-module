#!/system/bin/sh
# Install the module straight from a pushed source tree, no zip flash needed.
#
#   adb push q2ctrl-module /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/q2ctrl-module/src/mkmodule.sh"
#   adb reboot
#
# The previous version of this script carried its own inline copies of pair.sh
# and service.sh and pinned an old libtrackingutils hash. Those copies went stale
# the moment the real scripts changed, so running it silently reverted fixes.
# It now installs whatever is in the tree and holds no duplicated content.

SRC=$(cd "$(dirname "$0")/.." && pwd)
MOD=/data/adb/modules/q2ctrl

SB_STOCK=85a1788113f1faff2af91cd204f9d59a01e1040a
TU_STOCK=1ee35835de7cba4ad25407bef6612ad21a63b365

die() { echo "! $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"
[ -f "$SRC/module.prop" ] || die "$SRC does not look like the module tree"

# Same reasoning as customize.sh: if an older q2ctrl is already mounted, the path
# we want to verify is shadowed by our own library, so match that instead.
check() {
  found=$(sha1sum "$1" 2>/dev/null | cut -d' ' -f1)
  [ "$found" = "$2" ] && return 0
  [ -f "$3" ] && [ "$found" = "$(sha1sum "$3" 2>/dev/null | cut -d' ' -f1)" ] && {
    echo "- $1 is q2ctrl's own overlay, upgrading in place"; return 0; }
  die "$1 is $found, expected $2 - unsupported firmware"
}
check /vendor/lib64/libsyncboss.so      $SB_STOCK $MOD/system/vendor/lib64/libsyncboss.so
check /system/lib64/libtrackingutils.so $TU_STOCK $MOD/system/lib64/libtrackingutils.so

rm -rf $MOD
mkdir -p $MOD
for f in module.prop pair.sh q2addr.sh service.sh; do
  cp "$SRC/$f" $MOD/ || die "missing $f"
done
mkdir -p $MOD/system/vendor/lib64 $MOD/system/lib64
cp "$SRC/system/vendor/lib64/libsyncboss.so"  $MOD/system/vendor/lib64/ || die "missing libsyncboss"
cp "$SRC/system/lib64/libtrackingutils.so"    $MOD/system/lib64/       || die "missing libtrackingutils"

chmod 644 $MOD/module.prop $MOD/system/vendor/lib64/libsyncboss.so $MOD/system/lib64/libtrackingutils.so
chmod 755 $MOD/pair.sh $MOD/q2addr.sh $MOD/service.sh
chcon u:object_r:vendor_file:s0     $MOD/system/vendor/lib64/libsyncboss.so 2>/dev/null
chcon u:object_r:system_lib_file:s0 $MOD/system/lib64/libtrackingutils.so   2>/dev/null

echo "=== installed ==="
cat $MOD/module.prop
echo "libsyncboss      $(sha1sum $MOD/system/vendor/lib64/libsyncboss.so | cut -d' ' -f1)"
echo "libtrackingutils $(sha1sum $MOD/system/lib64/libtrackingutils.so | cut -d' ' -f1)"
echo
Q2CTRL_NORESTART=1 sh $MOD/q2addr.sh detect
echo
echo "reboot to activate"
