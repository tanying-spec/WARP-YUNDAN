#!/bin/sh
# Run ONLY on an ephemeral CI/test host in a private network namespace.
set -eu
[ "$(id -u)" = 0 ] || exit 1
[ ! -e /etc/warp-yundan ] || { echo 'Refusing to overwrite existing config'; exit 1; }
SCRIPT=$(pwd)/install.sh
mkdir -m 700 /etc/warp-yundan
cleanup() {
    sh "$SCRIPT" _proxy-route-off || true
    sh "$SCRIPT" stop || true
    rm -f /etc/warp-yundan/owner /etc/warp-yundan/tunnel.conf /etc/warp-yundan/addresses /etc/warp-yundan/endpoint /etc/warp-yundan/listen-port
    rmdir /etc/warp-yundan
    rm -rf -- /tmp/warp-yundan-test-menu
}
trap cleanup EXIT
umask 077
printf 'WARP-YUNDAN-v1\n' >/etc/warp-yundan/owner
private=$(wg genkey)
public=$(wg genkey | wg pubkey)
printf '[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\n' "$private" "$public" >/etc/warp-yundan/tunnel.conf
printf '172.16.0.2/32 2606:4700:110::123/128\n' >/etc/warp-yundan/addresses
printf '127.0.0.1:2408\n' >/etc/warp-yundan/endpoint
printf '0\n' >/etc/warp-yundan/listen-port
ip link set lo up
# Refuse another interface using the same WARP identity.
ip link add legacy-warp type wireguard
keyfile=$(mktemp)
printf '%s\n' "$private" >"$keyfile"
wg set legacy-warp private-key "$keyfile"
rm -f "$keyfile"
if sh "$SCRIPT" start; then echo 'duplicate WARP identity accepted'; exit 1; fi
ip link del legacy-warp
ip link add testnative type dummy
ip addr add 192.0.2.2/24 dev testnative
ip -6 addr add 2001:db8::2/64 dev testnative nodad
ip link set testnative up
ip route add default via 192.0.2.1
ip -6 route add default via 2001:db8::1
before=$(ip route show table main)
sh "$SCRIPT" start
mkdir /tmp/warp-yundan-test-menu
ln -s "$SCRIPT" /tmp/warp-yundan-test-menu/wy
[ "$(printf '5\n' | /tmp/warp-yundan-test-menu/wy | grep -c '^interface: wywarp$')" -eq 1 ]
rm -rf -- /tmp/warp-yundan-test-menu
[ "$(ip route show table main)" = "$before" ]
ip route get 1.1.1.1 oif wywarp | grep -q 'table 51889'
ip -6 route get 2606:4700:4700::1111 oif wywarp | grep -q 'table 51889'
ip route get 1.1.1.1 | grep -q 'testnative'
if sh "$SCRIPT" start; then echo 'duplicate start accepted'; exit 1; fi
ip link show wywarp >/dev/null
sh "$SCRIPT" restart
sh "$SCRIPT" _proxy-route-on hybrid
ip route get 1.1.1.1 mark 51890 | grep -q 'dev wywarp'
ip -6 route get 2606:4700:4700::1111 mark 51890 | grep -q 'dev testnative'
ip route get 192.0.2.3 mark 51890 | grep -q 'dev testnative'
ip route get 1.1.1.1 | grep -q 'testnative'
sh "$SCRIPT" stop
if ip route get 1.1.1.1 mark 51890 >/dev/null 2>&1; then echo 'mark leaked after WARP stop'; exit 1; fi
sh "$SCRIPT" start
ip route get 1.1.1.1 mark 51890 | grep -q 'dev wywarp'
# With no native IPv4 default route, marked IPv4 still has a WARP route.
ip route del default via 192.0.2.1
ip route get 1.1.1.1 mark 51890 | grep -q 'dev wywarp'
if ip route get 1.1.1.1 >/dev/null 2>&1; then exit 1; fi
ip route add default via 192.0.2.1
sh "$SCRIPT" _proxy-route-off
sh "$SCRIPT" _proxy-route-on all
ip -6 route get 2606:4700:4700::1111 mark 51890 | grep -q 'dev wywarp'
sh "$SCRIPT" stop
if ip -6 route get 2606:4700:4700::1111 mark 51890 >/dev/null 2>&1; then echo 'IPv6 mark leaked'; exit 1; fi
ip -6 route get 2606:4700:4700::1111 | grep -q 'dev testnative'
sh "$SCRIPT" start
sh "$SCRIPT" _proxy-route-off
sh "$SCRIPT" stop
sh "$SCRIPT" stop
if ip link show wywarp >/dev/null 2>&1; then exit 1; fi
if ip rule show | grep -q '^18589:'; then exit 1; fi
if ip -6 rule show | grep -q '^18589:'; then exit 1; fi
[ "$(ip route show table main)" = "$before" ]
ip rule add pref 18589 from 192.0.2.2 table main
if sh "$SCRIPT" start; then echo 'rule conflict accepted'; exit 1; fi
ip rule show | grep -q 'from 192.0.2.2 lookup main'
ip rule del pref 18589 from 192.0.2.2 table main
# Failure after interface creation must roll back the owned interface.
printf '999999\n' >/etc/warp-yundan/listen-port
if sh "$SCRIPT" start; then echo 'invalid port accepted'; exit 1; fi
if ip link show wywarp >/dev/null 2>&1; then exit 1; fi
echo 'PASS: native routes preserved, both families scoped, conflicts rejected, failure cleaned'
