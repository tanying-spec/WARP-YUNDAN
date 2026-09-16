#!/bin/sh
# WARP-YUNDAN: independent kernel WireGuard egress, not a default-route VPN.
set -efu
VERSION=1.1.0
HELPER_SHA256=6bb1e34fa017730e4be488526c7508a6894dc690a61e3bb2c1ed42958de86410
DIR=/etc/warp-yundan
BIN=/usr/local/sbin/warp-yundan
IFACE=wywarp
TABLE=51889
PREF=18589
LOCK=/run/warp-yundan.lock
LOCKED=0
WORK=
INSTALLING=0
COMMITTED=0

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
root_only() { [ "$(id -u)" = 0 ] || die '请使用 root 运行。'; }
lock() {
    mkdir "$LOCK" 2>/dev/null || die "另一个操作正在运行；若上次异常断电，请确认无操作后删除 $LOCK。"
    LOCKED=1
}
owned() { [ "$(cat "$DIR/owner" 2>/dev/null)" = WARP-YUNDAN-v1 ]; }
interface_owned() { ip -d link show "$IFACE" 2>/dev/null | grep -q 'alias WARP-YUNDAN-v1$'; }
stop_tunnel() {
    owned || return 0
    if ip link show "$IFACE" >/dev/null 2>&1; then
        interface_owned || { say '接口归属不匹配，拒绝删除。' >&2; return 1; }
        ip link del "$IFACE"
    fi
    # Delete only exact rules/routes created by this project; never flush a table.
    ip -4 rule del pref "$PREF" oif "$IFACE" table "$TABLE" 2>/dev/null || true
    ip -6 rule del pref "$PREF" oif "$IFACE" table "$TABLE" 2>/dev/null || true
}
cleanup() {
    code=$?
    trap - EXIT
    if [ "$INSTALLING" = 1 ] && [ "$COMMITTED" = 0 ]; then
        if [ -f "$DIR/service-owned" ]; then
            if command -v rc-update >/dev/null 2>&1; then
                rc-update del warp-yundan default >/dev/null 2>&1 || true
                rc-service warp-yundan zap >/dev/null 2>&1 || true
            elif [ -d /run/systemd/system ]; then
                systemctl disable warp-yundan.service >/dev/null 2>&1 || true
            fi
        fi
        stop_tunnel || true
        say '部署未完成：已撤销本次隧道，未改变系统默认路由。私密配置保留，可重试。' >&2
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        # WORK is exclusively a mktemp-created directory with this fixed prefix.
        case "$WORK" in /tmp/warp-yundan.*) rm -rf -- "$WORK" ;; esac
    fi
    [ "$LOCKED" = 0 ] || rmdir "$LOCK" 2>/dev/null || true
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_space() {
    free_kb=$(df -Pk / | awk 'END {print $4}')
    [ "$free_kb" -ge 65536 ] || die '根目录剩余空间不足 64 MiB。'
}
dependencies() {
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates wireguard-tools-wg iproute2
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates wireguard-tools iproute2
    else
        die '当前只支持 Alpine、Debian、Ubuntu；不会改动未知系统。'
    fi
}
download() {
    curl -fLsS --proto '=https' --connect-timeout 12 --max-time 120 --retry 1 "$1" -o "$2" ||
        die '下载失败。纯 IPv6 机器需能访问下载站；可通过 --wgcf 指定预先上传的官方二进制，不会擅自修改 DNS。'
}
get_wgcf() {
    case "$(uname -m)" in
        x86_64) arch=amd64; digest=69147e1a517c66129edd8ac8cb60484d6c9515178d7b4a2f95e3c925f225572a ;;
        aarch64|arm64) arch=arm64; digest=b9bdbdeaa3f9f4ba741ba55b8bd94c24f7166c27668eb7e8192ccf9746961182 ;;
        *) die '只提供 amd64 / arm64 支持。' ;;
    esac
    if [ -n "$WGCF_FILE" ]; then
        cp "$WGCF_FILE" "$WORK/wgcf"
    else
        download "https://github.com/ViRb3/wgcf/releases/download/v2.2.31/wgcf_2.2.31_linux_$arch" "$WORK/wgcf"
    fi
    actual=$(sha256sum "$WORK/wgcf" | awk '{print $1}')
    [ "$actual" = "$digest" ] || die 'wgcf SHA-256 不匹配，拒绝执行。'
    chmod 700 "$WORK/wgcf"
}
profile() {
    if [ -n "$PROFILE_FILE" ]; then
        [ ! -f "$DIR/wgcf-profile.conf" ] || die '已有配置；不覆盖账号。'
        cp "$PROFILE_FILE" "$DIR/wgcf-profile.conf"
    elif [ ! -s "$DIR/wgcf-profile.conf" ]; then
        if [ ! -s "$DIR/wgcf-account.toml" ]; then
            [ "$ACCEPT_TOS" = 1 ] || die '注册需 --accept-tos，表示接受 Cloudflare 服务条款：https://www.cloudflare.com/application/terms/'
        fi
        get_wgcf
        if [ ! -s "$DIR/wgcf-account.toml" ]; then
            say '注册独立 WARP 账号（不使用共享账号）……'
            (cd "$DIR" && timeout 60 "$WORK/wgcf" register --accept-tos >register.log 2>&1) ||
                die "注册失败，详细日志只保存在 $DIR/register.log；HTTP 429 可能是注册接口兼容问题，请勿反复刷注册。"
        fi
        (cd "$DIR" && timeout 30 "$WORK/wgcf" generate >generate.log 2>&1) || die "配置生成失败，查看 $DIR/generate.log。"
    fi
    # Build a strict data-only profile. Never execute imported PostUp/PreUp hooks.
    awk '
        /^[[:space:]]*\[Interface\][[:space:]]*$/ {section="interface"; print; next}
        /^[[:space:]]*\[Peer\][[:space:]]*$/ {section="peer"; print; next}
        /^[[:space:]]*\[/ {section="ignore"}
        section=="interface" && /^[[:space:]]*PrivateKey[[:space:]]*=/ {print}
        section=="peer" && /^[[:space:]]*(PublicKey|PresharedKey|AllowedIPs)[[:space:]]*=/ {print}
    ' "$DIR/wgcf-profile.conf" >"$DIR/tunnel.conf"
    awk -F= '/^[[:space:]]*Address[[:space:]]*=/ {print $2}' "$DIR/wgcf-profile.conf" | tr ',' ' ' >"$DIR/addresses"
    [ -s "$DIR/addresses" ] || die '配置缺少隧道地址。'
    for name in owner wgcf-profile.conf wgcf-account.toml tunnel.conf addresses register.log generate.log; do
        if [ -f "$DIR/$name" ]; then chmod 600 "$DIR/$name"; fi
    done
}
vacant() {
    ! ip link show "$IFACE" >/dev/null 2>&1 || die "接口 $IFACE 已存在。"
    for family in -4 -6; do
        [ -z "$(ip "$family" route show table "$TABLE" 2>/dev/null)" ] || die "路由表 $TABLE 被占用。"
        ! ip "$family" rule show | grep -q "^$PREF:" || die "规则优先级 $PREF 被占用。"
    done
}
start_tunnel() {
    owned || die '未找到本项目配置，请先安装。'
    vacant
    ip link add "$IFACE" type wireguard || die '无法创建内核 WireGuard 接口：需宿主机支持 WireGuard，并授予 CAP_NET_ADMIN。有 TUN 设备不代表满足条件。'
    if ! ip link set dev "$IFACE" alias WARP-YUNDAN-v1; then
        ip link del "$IFACE"
        return 1
    fi
    if ! configure_tunnel; then
        stop_tunnel
        return 1
    fi
}
configure_tunnel() {
    wg setconf "$IFACE" "$DIR/tunnel.conf" || return 1
    peer=$(wg show "$IFACE" peers)
    [ "$(printf '%s\n' "$peer" | wc -l)" -eq 1 ] && [ -n "$peer" ] || return 1
    endpoint=$(cat "$DIR/endpoint")
    listen_port=$(cat "$DIR/listen-port")
    case "$listen_port" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#listen_port}" -le 5 ] && [ "$listen_port" -le 65535 ] || return 1
    wg set "$IFACE" listen-port "$listen_port" peer "$peer" endpoint "$endpoint" persistent-keepalive 25 || return 1
    addresses=$(cat "$DIR/addresses")
    for addr in $addresses; do
        case "$addr" in
            *:*) ip -6 addr add "$addr" dev "$IFACE" nodad || return 1 ;;
            *) ip -4 addr add "$addr" dev "$IFACE" || return 1 ;;
        esac
    done
    ip link set "$IFACE" mtu 1280 up || return 1
    ip -4 route add default dev "$IFACE" table "$TABLE" || return 1
    ip -6 route add default dev "$IFACE" table "$TABLE" || return 1
    ip -4 rule add pref "$PREF" oif "$IFACE" table "$TABLE" || return 1
    ip -6 rule add pref "$PREF" oif "$IFACE" table "$TABLE" || return 1
    if [ -f "$DIR/proxy-mode" ]; then proxy_routes_on "$(cat "$DIR/proxy-mode")" || return 1; fi
}
probe_family() {
    family=$1
    trace=$(curl "$family" --interface "$IFACE" -fsS --connect-timeout 5 --max-time 9 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
    printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || return 1
    # --resolve tests an IPv4-only origin through IPv6 transport even when the
    # system DNS64 resolver suppresses A answers. TLS still verifies the hostname.
    if [ "$family" = -4 ]; then
        code=$(curl -4 --interface "$IFACE" --resolve one.one.one.one:443:1.1.1.1 -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 9 https://one.one.one.one/cdn-cgi/trace 2>/dev/null) || return 1
        [ "$code" = 200 ] || return 1
    fi
    code=$(curl "$family" --interface "$IFACE" -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 9 https://www.google.com/generate_204 2>/dev/null) || return 1
    [ "$code" = 204 ] || return 1
    printf '%s\n' "$trace" | grep -E '^(ip|colo|warp)='
}
proxy_routes_on() {
    mode=$1
    case "$mode" in all|hybrid) ;; *) die '无效代理接入模式。' ;; esac
    interface_owned || die 'WARP 接口未就绪。'
    if [ ! -f "$DIR/proxy-routing-owned" ]; then
        for family in -4 -6; do
            [ -z "$(ip "$family" route show table 51890 2>/dev/null)" ] || die '代理路由表 51890 被占用。'
            ! ip "$family" rule show | grep -Eq '^1859[01]:' || die '代理路由优先级被占用。'
            ! ip "$family" rule show | grep -Eq 'fwmark (0xcab2|51890)(/| )' || die '代理路由标记被占用。'
        done
        touch "$DIR/proxy-routing-owned"
    fi
    families=-4; [ "$mode" = all ] && families='-4 -6'
    for family in $families; do
        # Keep a fail-closed route in the marked table. If wywarp disappears,
        # marked sockets fail instead of leaking through the native default route.
        ip "$family" route replace prohibit default metric 32760 table 51890 || return 1
        ip "$family" route replace default dev "$IFACE" metric 10 table 51890 || return 1
        if ! ip "$family" rule show | grep -q '^18590:'; then
            ip "$family" rule add pref 18590 fwmark 51890 lookup main suppress_prefixlength 0 || return 1
        fi
        if ! ip "$family" rule show | grep -q '^18591:'; then
            ip "$family" rule add pref 18591 fwmark 51890 lookup 51890 || return 1
        fi
    done
    printf '%s\n' "$mode" >"$DIR/proxy-mode"
}
proxy_routes_off() {
    [ -f "$DIR/proxy-routing-owned" ] || return 0
    for family in -4 -6; do
        ip "$family" rule del pref 18590 fwmark 51890 lookup main suppress_prefixlength 0 2>/dev/null || true
        ip "$family" rule del pref 18591 fwmark 51890 lookup 51890 2>/dev/null || true
        ip "$family" route del default dev "$IFACE" metric 10 table 51890 2>/dev/null || true
        ip "$family" route del prohibit default metric 32760 table 51890 2>/dev/null || true
    done
    rm -f "$DIR/proxy-mode" "$DIR/proxy-routing-owned"
}
proxy_dispatch() {
    if ! owned || [ ! -f "$DIR/installed" ]; then die '请先安装 WARP-YUNDAN。'; fi
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then apk add --no-cache python3 py3-yaml
        elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y --no-install-recommends python3 python3-yaml
        else die '代理接入需要 Python3 和 PyYAML。'; fi
    fi
    helper="$DIR/proxy.py"
    if [ ! -f "$helper" ] || [ "$(sha256sum "$helper" | awk '{print $1}')" != "$HELPER_SHA256" ]; then
        WORK=$(mktemp -d /tmp/warp-yundan.XXXXXX)
        download "https://raw.githubusercontent.com/tanying-spec/WARP-YUNDAN/v$VERSION/proxy.py" "$WORK/proxy.py"
        [ "$(sha256sum "$WORK/proxy.py" | awk '{print $1}')" = "$HELPER_SHA256" ] || die '接入模块校验失败。'
        cp "$WORK/proxy.py" "$helper"; chmod 600 "$helper"
    fi
    python3 "$helper" "$@"
}
health() {
    pass4=0
    say '检查 WARP IPv4：'
    if probe_family -4; then pass4=1; else say 'IPv4 未通过。'; fi
    say '检查 WARP IPv6：'
    if ! probe_family -6; then say 'IPv6 未通过；原生 IPv6 不受影响。'; fi
    [ "$pass4" = 1 ]
}
select_endpoint() {
    candidates=
    if ip -6 route get 2606:4700:d0::a29f:c001 >/dev/null 2>&1; then
        candidates='[2606:4700:d0::a29f:c001]:2408 [2606:4700:d0::a29f:c001]:500 [2606:4700:d0::a29f:c001]:4500'
    fi
    if ip -4 route get 162.159.192.1 >/dev/null 2>&1; then
        candidates="$candidates 162.159.192.1:2408 162.159.192.1:500 162.159.192.1:4500"
    fi
    [ -n "$candidates" ] || die '没有可用的原生 IP 路由。'
    for endpoint in $candidates; do
        for listen_port in 0 38386; do
            say "测试接入 $endpoint / 本地端口 $listen_port（0 表示随机）"
            printf '%s\n' "$endpoint" >"$DIR/endpoint"
            printf '%s\n' "$listen_port" >"$DIR/listen-port"
            # Recreate for every candidate to avoid reusing another endpoint's handshake.
            if start_tunnel; then
                if probe_family -4; then
                    wg show "$IFACE" listen-port >"$DIR/listen-port"
                    stop_tunnel
                    if start_tunnel && probe_family -4; then return 0; fi
                fi
            fi
            stop_tunnel
        done
    done
    die '所有候选都未通过 IPv4 WARP＋Google 连通性验证；不启用开机启动。可能是 UDP 限制、账号或服务侧问题。'
}
service_install() {
    if command -v rc-service >/dev/null 2>&1; then
        [ ! -e /etc/init.d/warp-yundan ] || [ -f "$DIR/service-owned" ] || die '已有同名 OpenRC 服务。'
        cat >/etc/init.d/warp-yundan <<'EOF'
#!/sbin/openrc-run
description="WARP-YUNDAN independent WireGuard outbound"
depend() { need net; after networking; }
start() { ebegin "Starting WARP-YUNDAN"; /usr/local/sbin/warp-yundan start; eend $?; }
stop() { ebegin "Stopping WARP-YUNDAN"; /usr/local/sbin/warp-yundan stop; eend $?; }
EOF
        chmod 755 /etc/init.d/warp-yundan
        touch "$DIR/service-owned"
        rc-update add warp-yundan default
        # The installer holds the lock; service start would otherwise deadlock.
        rc-service warp-yundan zap >/dev/null 2>&1 || true
    elif [ -d /run/systemd/system ]; then
        [ ! -e /etc/systemd/system/warp-yundan.service ] || [ -f "$DIR/service-owned" ] || die '已有同名 systemd 服务。'
        cat >/etc/systemd/system/warp-yundan.service <<'EOF'
[Unit]
Description=WARP-YUNDAN independent WireGuard outbound
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/warp-yundan start
ExecStop=/usr/local/sbin/warp-yundan stop
TimeoutStartSec=30
[Install]
WantedBy=multi-user.target
EOF
        touch "$DIR/service-owned"
        systemctl daemon-reload
        systemctl enable warp-yundan.service
    else
        die '未识别到 OpenRC/systemd，无法设置开机启动。'
    fi
}
install() {
    PROFILE_FILE=; WGCF_FILE=; ACCEPT_TOS=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --accept-tos) ACCEPT_TOS=1; shift ;;
            --profile) [ "$#" -ge 2 ] || die '--profile 缺少路径'; PROFILE_FILE=$2; shift 2 ;;
            --wgcf) [ "$#" -ge 2 ] || die '--wgcf 缺少路径'; WGCF_FILE=$2; shift 2 ;;
            *) die "未知参数：$1" ;;
        esac
    done
    [ ! -e "$DIR" ] || owned || die "$DIR 已存在但不属于本项目。"
    if [ -e "$DIR/installed" ]; then
        if [ "$(readlink -f "$0")" != "$BIN" ]; then cp "$0" "$BIN"; chmod 755 "$BIN"; fi
        say "管理命令已更新到 $VERSION，保留原账号、隧道和代理配置。"
        return 0
    fi
    [ ! -e "$BIN" ] || owned || die "$BIN 已存在，拒绝覆盖。"
    check_space
    dependencies
    vacant
    WORK=$(mktemp -d /tmp/warp-yundan.XXXXXX)
    umask 077
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    printf 'WARP-YUNDAN-v1\n' >"$DIR/owner"
    INSTALLING=1
    profile
    select_endpoint
    health || die '最终健康检查失败。'
    mkdir -p /usr/local/sbin
    cp "$0" "$BIN"
    chmod 755 "$BIN"
    stop_tunnel
    service_install
    # Release lock before asking the service manager to invoke this script.
    rmdir "$LOCK"; LOCKED=0
    if command -v rc-service >/dev/null 2>&1; then rc-service warp-yundan start; else systemctl start warp-yundan; fi
    lock
    if ! health; then
        if command -v rc-update >/dev/null 2>&1; then rc-update del warp-yundan default; else systemctl disable warp-yundan; fi
        die '服务启动后验证失败，已取消开机启动。'
    fi
    touch "$DIR/installed"
    COMMITTED=1
    say "安装成功 v$VERSION。接口 $IFACE；仅显式绑定此接口的流量走 WARP。"
    say '测试：curl -4 --interface wywarp https://www.cloudflare.com/cdn-cgi/trace'
    say '管理：warp-yundan status | check | restart | uninstall'
}
uninstall() {
    owned || die '没有属于本项目的安装。'
    if [ -e "$DIR/proxy-state.json" ] || [ -e "$DIR/proxy-mode" ]; then die '请先执行 warp-yundan proxy detach。'; fi
    stop_tunnel
    if [ -f "$DIR/service-owned" ]; then
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del warp-yundan default 2>/dev/null || true
            rc-service warp-yundan zap 2>/dev/null || true
            rm -f /etc/init.d/warp-yundan
        elif [ -d /run/systemd/system ]; then
            systemctl disable warp-yundan.service 2>/dev/null || true
            # Stop calls back into us; release the operation lock first.
            rmdir "$LOCK"; LOCKED=0
            systemctl stop warp-yundan.service || true
            lock
            rm -f /etc/systemd/system/warp-yundan.service
            systemctl daemon-reload
        fi
    fi
    # Retain credentials for reinstall; never remove unrelated packages/accounts.
    rm -f "$DIR/installed" "$DIR/service-owned" "$BIN"
    say "已移除隧道、启动服务和管理命令；账号保留于 $DIR（root-only），便于重装复用。"
}
usage() {
    say "WARP-YUNDAN v$VERSION"
    say '安装：sh install.sh install --accept-tos [--wgcf /path/to/verified-binary]'
    say '导入：sh install.sh install --profile /path/to/wgcf-profile.conf'
    say '管理：warp-yundan start|stop|restart|status|check|uninstall'
    say '代理接入：warp-yundan proxy（交互菜单）或 proxy attach --mode hybrid|all'
    say '不提供 SOCKS5 端口，不替换默认路由，不自动接管现有代理。'
}
main() {
    action=${1:-help}; [ "$#" = 0 ] || shift
    case "$action" in help|--help|-h) usage; return ;; esac
    root_only
    case "$action" in
        check) owned || die '未安装'; health ;;
        status) owned || die '未安装'; wg show "$IFACE"; say 'WARP 是否可用请执行 warp-yundan check。' ;;
        install) lock; install "$@" ;;
        start) lock; start_tunnel ;;
        stop) lock; stop_tunnel ;;
        restart) lock; stop_tunnel; start_tunnel ;;
        uninstall) lock; uninstall ;;
        proxy) lock; proxy_dispatch "$@" ;;
        _proxy-route-on) proxy_routes_on "$@" ;;
        _proxy-route-off) proxy_routes_off ;;
        *) usage; exit 1 ;;
    esac
}
main "$@"
