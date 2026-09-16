#!/bin/sh
# Run ONLY on an ephemeral CI/test host in a private network namespace.
set -eu
[ "$(id -u)" = 0 ] || exit 1
[ ! -e /etc/warp-yundan ] || { echo 'Refusing to overwrite existing config'; exit 1; }
SCRIPT=$(pwd)/install.sh
mkdir -m 700 /etc/warp-yundan
cleanup() {
    sh "$SCRIPT" stop || true
    rm -f /etc/warp-yundan/owner /etc/warp-yundan/tunnel.conf /etc/warp-yundan/addresses /etc/warp-yundan/endpoint /etc/warp-yundan/listen-port
    rmdir /etc/warp-yundan
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
ip link add testnative type dummy
ip addr add 192.0.2.2/24 dev testnative
ip link set testnative up
ip route add default via 192.0.2.1
before=$(ip route show table main)
sh "$SCRIPT" start
[ "$(ip route show table main)" = "$before" ]
ip route get 1.1.1.1 oif wywarp | grep -q 'table 51889'
ip -6 route get 2606:4700:4700::1111 oif wywarp | grep -q 'table 51889'
ip route get 1.1.1.1 | grep -q 'testnative'
if sh "$SCRIPT" start; then echo 'duplicate start accepted'; exit 1; fi
ip link show wywarp >/dev/null
sh "$SCRIPT" restart
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
