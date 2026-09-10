#!/opt/bb/busybox sh
# busybox udhcpc callback script.
#
# busybox exports $mask as the *prefix length* (e.g. 24), not a dotted quad,
# so `ip addr add $ip/$mask` is directly usable.
PATH=/opt/bb:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RESOLV_CONF=/etc/resolv.conf

deconfig() {
    ip link set "$interface" up 2>/dev/null
    ip addr flush dev "$interface" 2>/dev/null
    ip route flush dev "$interface" 2>/dev/null
}

bound() {
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "$ip/${mask:-24}" dev "$interface"
    ip link set "$interface" up

    if [ -n "$router" ]; then
        ip route del default dev "$interface" 2>/dev/null
        for r in $router; do
            ip route add default via "$r" dev "$interface" 2>/dev/null && break
        done
    fi

    # /etc/resolv.conf must be a writable regular file (build-rootfs.sh makes
    # sure the Ubuntu systemd-resolved symlink is gone).
    {
        [ -n "$domain" ] && echo "search $domain"
        for d in $dns; do
            echo "nameserver $d"
        done
        # Fall back to a public resolver if the lease carried no DNS server.
        [ -z "$dns" ] && echo "nameserver 1.1.1.1"
    } > "$RESOLV_CONF".tmp 2>/dev/null && mv "$RESOLV_CONF".tmp "$RESOLV_CONF" 2>/dev/null

    echo "KAKA-DHCP: $1 $interface $ip/${mask:-24} gw=${router:-none} dns=${dns:-none}"
}

case "$1" in
    deconfig)
        deconfig
        ;;
    bound|renew)
        bound "$1"
        ;;
    leasefail|nak)
        echo "KAKA-DHCP: $1 on $interface"
        ;;
    *)
        echo "KAKA-DHCP: unknown event '$1'"
        ;;
esac

exit 0
