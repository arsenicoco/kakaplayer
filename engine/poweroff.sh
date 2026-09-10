#!/opt/bb/busybox sh
# Clean-shutdown handler.  The macOS host connects to vsock port 6880 and
# socat execs this script (socat splits EXEC: on whitespace, so this must be a
# script path rather than an inline `sh -c "..."`).
#
# The Kata guest kernel is built without CONFIG_MAGIC_SYSRQ, so
# /proc/sysrq-trigger does not exist; use busybox poweroff instead.
PATH=/opt/bb:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

echo "KAKA-INIT: poweroff requested via vsock 6880" > /dev/console 2>/dev/null
echo "KAKA-INIT: poweroff requested via vsock 6880"

/opt/bb/busybox sync
/opt/bb/busybox umount -a -r 2>/dev/null
/opt/bb/busybox sync
/opt/bb/busybox poweroff -f
