SKIPUNZIP=0

SB_STOCK=85a1788113f1faff2af91cd204f9d59a01e1040a
TU_STOCK=1ee35835de7cba4ad25407bef6612ad21a63b365
MODDIR=/data/adb/modules/q2ctrl

# Verify the partition carries the build these patches were made against.
#
# The catch on an upgrade: an already-mounted q2ctrl sits on top of the very path
# we want to inspect, so what is readable there is our own library rather than
# the partition's. Recognise that case by matching it against the installed
# module's copy, which is the file doing the shadowing.
check() {
  target=$1
  want=$2
  mounted=$3

  found=$(sha1sum "$target" 2>/dev/null | cut -d' ' -f1)
  [ "$found" = "$want" ] && return 0

  if [ -f "$mounted" ] && [ "$found" = "$(sha1sum "$mounted" 2>/dev/null | cut -d' ' -f1)" ]; then
    ui_print "- $target is q2ctrl's own overlay, upgrading in place"
    return 0
  fi

  ui_print "! $target does not match the build this module targets"
  ui_print "!   expected $want"
  ui_print "!   found    ${found:-nothing}"
  ui_print "! Installing anyway could break headset tracking. Aborting."
  abort "! Unsupported firmware"
}

if [ -f $MODDIR/module.prop ]; then
  ui_print "- Found $(grep '^version=' $MODDIR/module.prop | cut -d= -f2), replacing it"
fi

check /vendor/lib64/libsyncboss.so      $SB_STOCK $MODDIR/system/vendor/lib64/libsyncboss.so
check /system/lib64/libtrackingutils.so $TU_STOCK $MODDIR/system/lib64/libtrackingutils.so
ui_print "- Libraries verified"

set_perm_recursive "$MODPATH/system" 0 0 0755 0644
set_perm "$MODPATH/system/vendor/lib64/libsyncboss.so"  0 0 0644 u:object_r:vendor_file:s0
set_perm "$MODPATH/system/lib64/libtrackingutils.so"    0 0 0644 u:object_r:system_lib_file:s0
set_perm "$MODPATH/pair.sh"    0 0 0755
set_perm "$MODPATH/q2addr.sh"  0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# Nothing about this module is specific to one headset. The only per-device value
# is which controller addresses are Quest 2, and those are data, not code, so pick
# them up from the calibration blobs already on this unit. A headset with no Quest
# 2 paired yet installs fine and gets configured by pair.sh later.
ui_print "- Looking for already-paired Quest 2 controllers"
Q2CTRL_MOD="$MODPATH" Q2CTRL_NORESTART=1 sh "$MODPATH/q2addr.sh" detect 2>&1 | while read -r l; do
  ui_print "  $l"
done

ui_print " "
ui_print "- Pairing bypass set: persist.ovr.tracking.freepair=1 (applies on reboot)"
ui_print " "
ui_print "- Reboot, then pair a Quest 2 controller with:"
ui_print "    su -c /data/adb/modules/q2ctrl/pair.sh 1     (left)"
ui_print "    su -c /data/adb/modules/q2ctrl/pair.sh 2     (right)"
ui_print "- Check or change what is configured with:"
ui_print "    su -c /data/adb/modules/q2ctrl/q2addr.sh show"
