#!/system/bin/sh
# Pair a Quest 2 Touch into one of the two controller slots.
#
# Two things this gets right that the original did not. `service call` prints a
# raw result parcel that reads as garbage, so it is discarded in favour of the
# pairing table. And the success check is scoped to the slot being paired: a
# whole-output grep for CONNECTED matches the *other* controller and reports
# success instantly without anything having been paired.

MOD=/data/adb/modules/q2ctrl
STOCK_SB=85a1788113f1faff2af91cd204f9d59a01e1040a
SLOT=${1:-1}
TMO=${2:-90000}

# The slot number here is our own convention. The service wants a DEVICE TYPE,
# and those are not what you would guess: `getSupportedDeviceTypes` (txn 1)
# returns {1, 0} and `getDeviceTypeDescription` (txn 2) names them
# 1 = "LeftHand", 0 = "RightHand". Passing anything else does not merely fail,
# it takes trackingservice down with it, so DEVTYPE must only ever be 0 or 1.
case "$SLOT" in
  1|left)  HAND="left"  ; DEVTYPE=1 ; HANDPAT="Type: +Left"  ; COMBO="Menu + Y" ;;
  2|right) HAND="right" ; DEVTYPE=0 ; HANDPAT="Type: +Right" ; COMBO="Oculus + B" ;;
  *) echo "usage: pair.sh [1=left|2=right] [timeout_ms]"; exit 1 ;;
esac

[ "$(id -u)" = "0" ] || { echo "! must run as root: su -c $0 $SLOT"; exit 1; }

# Pairing a Q2 needs the type-acceptance patch live. Stock libsyncboss knows
# exactly one pulsar type (LCON/17) and drops a Jedi advert (20) before the radio
# ever gets to bond, so without it the scan can only time out.
LIVE=$(sha1sum /vendor/lib64/libsyncboss.so 2>/dev/null | cut -d' ' -f1)
if [ "$LIVE" = "$STOCK_SB" ]; then
  echo "! /vendor/lib64/libsyncboss.so is STOCK - the Q2 type patch is not loaded."
  if [ -f $MOD/disable ]; then
    echo "!   the q2ctrl module is disabled. Re-enable it and reboot:"
    echo "!     rm $MOD/disable && reboot"
  else
    echo "!   check the module mounted: ls -la $MOD/"
  fi
  echo "! A Quest 1 controller would still pair; a Quest 2 cannot."
  exit 1
fi

# With hardware_type 4 the Q2 reports as JEDI, and ControllerGlue refuses to pair
# a ControllerType it does not recognise. It fails silently: the radio sees the
# advert for the whole scan and the call just times out. The module sets this at
# boot via system.prop, so this only fires if it has not been applied yet.
if [ "$(getprop persist.ovr.tracking.freepair)" != "1" ]; then
  echo "- persist.ovr.tracking.freepair was unset, setting it"
  resetprop persist.ovr.tracking.freepair 1 2>/dev/null \
    || setprop persist.ovr.tracking.freepair 1
  tpid=$(pidof trackingservice 2>/dev/null)
  if [ -n "$tpid" ]; then
    kill -9 $tpid 2>/dev/null
    echo "- restarted trackingservice to pick it up, waiting"
    sleep 10
  fi
fi

# Just the line for the hand we are pairing, so the other controller's state can
# never be mistaken for ours.
slot_line() { dumpsys OVRRemoteService 2>/dev/null | grep -E "Paired device:.*$HANDPAT"; }
slot_addr() { slot_line | sed -n 's/.*Paired device: *\([0-9a-f]*\).*/\1/p'; }
slot_up()   { slot_line | grep -q 'ExternalStatus: CONNECTED'; }

was_addr=$(slot_addr)
was_up=no; slot_up && was_up=yes

echo "libsyncboss $LIVE (patched)"
echo "pairing into slot $SLOT, $HAND - hold $COMBO until the LED blinks fast"
if [ -n "$was_addr" ]; then
  echo "current occupant: $was_addr (connected: $was_up) - pairing EVICTS it"
fi
echo

logcat -c 2>/dev/null
# txn 13 = scanAndPairDevice(type, timeout_ms, out)
service call OVRRemoteService 13 i32 "$DEVTYPE" i32 "$TMO" >/dev/null 2>&1

# Success is this slot holding a different controller, or the one it already held
# coming up. Poll for either; do not assume the binder call blocks.
secs=$((TMO / 1000))
[ "$secs" -lt 10 ] && secs=10
i=0
ok=no
while [ $i -lt $secs ]; do
  now_addr=$(slot_addr)
  if [ -n "$now_addr" ] && [ "$now_addr" != "$was_addr" ]; then ok=new; break; fi
  if [ "$was_up" = "no" ] && slot_up; then ok=up; break; fi
  sleep 2
  i=$((i + 2))
done

echo "pairing table after ${i}s:"
dumpsys OVRRemoteService 2>/dev/null | grep 'Paired device:' | sed 's/^/  /'
echo

rej=$(logcat -d 2>/dev/null | grep -m1 'Unexpected pulsar hardware type')
if [ -n "$rej" ]; then
  echo "! controller was REJECTED on type by the radio HAL:"
  echo "!   $rej"
  echo "! the type patch is not covering this hardware type."
  exit 1
fi

# The silent one. The radio hears the advert fine; ControllerGlue drops it.
uns=$(logcat -d 2>/dev/null | grep -m1 'is of unsupported type')
if [ -n "$uns" ]; then
  echo "! ControllerGlue refused the controller's type:"
  echo "!   $uns"
  echo "! persist.ovr.tracking.freepair must be 1 AND trackingservice restarted"
  echo "! since it was set. Currently: $(getprop persist.ovr.tracking.freepair)"
  exit 1
fi

case "$ok" in
  new) echo "paired: slot $SLOT now holds $(slot_addr)" ;;
  up)  echo "reconnected: $(slot_addr) came up in slot $SLOT" ;;
  no)
    echo "! nothing changed in the $HAND slot after ${i}s."
    if [ "$was_up" = "yes" ]; then
      echo "! it was already connected before this ran, so there was nothing to do."
    else
      echo "! the controller was probably never in pairing mode, or the scan timed"
      echo "! out. Retry with the LED blinking fast."
    fi
    exit 1
    ;;
esac

echo
echo "Recording Quest 2 controllers so they get the right LED geometry:"
$MOD/q2addr.sh detect || {
  echo
  echo "! paired, but no Quest 2 was detected to record. If this was a Quest 1"
  echo "! that is correct and nothing more is needed."
}

echo
echo "Wear the headset (or cover the proximity sensor) before judging tracking."
echo "The controller radio powers down whenever the HMD is idle."
