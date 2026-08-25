#!/system/bin/sh
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
n=0
i=0
while [ $i -lt 60 ]; do
  n=$(dumpsys OVRRemoteService 2>/dev/null | grep -c 'ExternalStatus: CONNECTED_ACTIVE')
  [ "$n" -ge 2 ] && break
  sleep 2
  i=$((i+1))
done
[ "$n" -ge 2 ] || exit 0
sleep 5
am force-stop com.oculus.shellenv
killall com.oculus.vrshell 2>/dev/null
exit 0
