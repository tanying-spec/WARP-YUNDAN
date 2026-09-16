#!/usr/bin/env python3
"""Optional, transactional integration for single-file server proxy configs.

No daemon: runs only during explicit management. Never prints configurations,
credentials, or core validation output. The shell caller owns the operation lock.
"""
import argparse
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

import yaml

DIR = Path('/etc/warp-yundan')
BIN = '/usr/local/sbin/warp-yundan'
STATE = DIR / 'proxy-state.json'
TAG = 'WARP-YUNDAN-EGRESS'
PROBE = 'WARP-YUNDAN-CHECK'
DNS = 'WARP-YUNDAN-DNS'
MARK = 51890


class Error(Exception):
    pass


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate keys rather than silently changing their interpretation."""


def unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise Error('配置包含重复字段；请先整理，避免解析歧义。')
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_config(path, engine):
    raw = path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise Error('配置超过 4 MiB，不自动处理。')
    try:
        if engine == 'mihomo':
            data = yaml.load(raw, Loader=UniqueLoader)
        else:
            def unique_pairs(pairs):
                result = {}
                for key, value in pairs:
                    if key in result:
                        raise Error('JSON 存在重复字段。')
                    result[key] = value
                return result
            data = json.loads(raw, object_pairs_hook=unique_pairs)
    except (ValueError, yaml.YAMLError) as exc:
        raise Error('配置无法安全解析。sing-box 当前仅支持标准 JSON 单文件。') from exc
    if not isinstance(data, dict):
        raise Error('配置根节点必须是对象。')
    return raw, data


def encode(data, engine):
    if engine == 'mihomo':
        return yaml.safe_dump(data, allow_unicode=True, sort_keys=False).encode()
    return (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()


def replace_rule(rule):
    # Only terminal policy tokens, never domain substrings / rule provider names.
    if not isinstance(rule, str):
        raise Error('不支持非字符串规则。')
    parts = rule.split(',')
    index = -2 if parts[-1].strip() == 'no-resolve' else -1
    if parts[index].strip() == 'DIRECT':
        parts[index] = TAG
    return ','.join(parts)


def reject_keys(obj, keys):
    if any(obj.get(key) not in (None, '', 0, False) for key in keys):
        raise Error('已有接口绑定、路由标记或特殊拨号设置，拒绝覆盖；请手动接入。')


def transform(data, engine, mode, probe):
    """Preserve routing/reject decisions; replace only direct server egress."""
    data = copy.deepcopy(data)
    if engine == 'mihomo':
        if data.get('mode', 'rule').lower() != 'rule':
            raise Error('Mihomo 仅支持 rule 模式；不会修改 global/direct 模式语义。')
        if data.get('tun', {}).get('enable') or data.get('redir-port') or data.get('tproxy-port'):
            raise Error('TUN/透明代理配置需手动接入。')
        if data.get('proxy-providers'):
            raise Error('检测到动态代理订阅，不自动修改。')
        reject_keys(data, ('interface-name', 'routing-mark'))
        proxies = data.setdefault('proxies', [])
        if any(p.get('type') != 'direct' for p in proxies):
            raise Error('检测到远端代理链；此功能面向直连出口的服务端，不替换已有远端节点。')
        names = {p.get('name') for p in proxies} | {p.get('name') for p in data.get('proxy-groups', [])}
        if TAG in names or any(x.get('name') == PROBE for x in data.get('listeners', [])):
            raise Error('保留名称冲突。')
        for p in proxies:
            reject_keys(p, ('interface-name', 'routing-mark', 'dialer-proxy'))
            p.update({'routing-mark': MARK, 'ip-version': 'ipv6-prefer' if mode == 'hybrid' else 'ipv4-prefer'})
        proxies.append({'name': TAG, 'type': 'direct', 'routing-mark': MARK,
                        'ip-version': 'ipv6-prefer' if mode == 'hybrid' else 'ipv4-prefer'})
        data['ipv6'] = True
        if 'dns' in data:
            data['dns']['ipv6'] = True
        rules = data.get('rules', [])
        if not any(isinstance(r, str) and r.startswith(('MATCH,', 'FINAL,')) for r in rules):
            raise Error('需要显式 MATCH/FINAL 终止规则，避免改写隐式默认策略。')
        data['rules'] = [replace_rule(r) for r in rules]
        for name, rules in data.get('sub-rules', {}).items():
            data['sub-rules'][name] = [replace_rule(r) for r in rules]
        for group in data.get('proxy-groups', []):
            group['proxies'] = [TAG if x == 'DIRECT' else x for x in group.get('proxies', [])]
        for listener in data.get('listeners', []):
            if listener.get('proxy') == 'DIRECT':
                listener['proxy'] = TAG
        # A protected loopback listener tests the same process and normal rules.
        # It does NOT skip rules with a hard-coded outbound override.
        data.setdefault('listeners', []).append({
            'name': PROBE, 'type': 'socks', 'listen': '127.0.0.1', 'port': probe['port'],
            'users': [{'username': 'warp-check', 'password': probe['password']}],
        })
    else:
        if data.get('endpoints'):
            raise Error('已有隧道 endpoints，拒绝自动改写。')
        if any(x.get('type') in ('tun', 'redirect', 'tproxy') for x in data.get('inbounds', [])):
            raise Error('TUN/透明代理配置需手动接入。')
        route = data.setdefault('route', {})
        reject_keys(route, ('default_interface', 'default_mark', 'auto_detect_interface'))
        outbounds = data.get('outbounds', [])
        if any(x.get('type') not in ('direct', 'block', 'dns') for x in outbounds):
            raise Error('检测到远端代理链/选择组，需手动接入。')
        directs = [x for x in outbounds if x.get('type') == 'direct']
        if not directs:
            raise Error('没有明确的 direct 出口。')
        if any(x.get('tag') == PROBE for x in data.get('inbounds', [])):
            raise Error('保留的诊断入口名称冲突。')
        dns = data.setdefault('dns', {})
        if any(x.get('tag') == DNS for x in dns.get('servers', [])):
            raise Error('保留的 DNS 名称冲突。')
        dns.setdefault('servers', []).append({'type': 'local', 'tag': DNS})
        for outbound in directs:
            reject_keys(outbound, ('bind_interface', 'inet4_bind_address', 'inet6_bind_address',
                                   'routing_mark', 'detour', 'network_strategy'))
            if outbound.get('domain_resolver') or outbound.get('domain_strategy'):
                raise Error('direct 已有专用 DNS 策略，不自动替换。')
            outbound.update({'routing_mark': MARK, 'domain_resolver': {
                'server': DNS, 'strategy': 'prefer_ipv6' if mode == 'hybrid' else 'prefer_ipv4',
            }})
        data.setdefault('inbounds', []).append({
            'type': 'mixed', 'tag': PROBE, 'listen': '127.0.0.1', 'listen_port': probe['port'],
            'users': [{'username': 'warp-check', 'password': probe['password']}],
        })
    return data


def command(args, timeout=30):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Error('命令无法执行或超时：' + str(args[0])) from exc
    if result.returncode:
        # Logs may contain secrets from third-party cores; keep local root-only.
        log = DIR / 'proxy-error.log'
        atomic(log, result.stdout, 0o600)
        raise Error('操作失败，私密日志保存在 /etc/warp-yundan/proxy-error.log。')
    return result.stdout.decode(errors='replace')


def atomic(path, data, mode=0o600, uid=None, gid=None):
    fd, temporary = tempfile.mkstemp(prefix='.wy-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        if uid is not None:
            os.fchown(fd, uid, gid)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_state(state):
    atomic(STATE, json.dumps(state, ensure_ascii=False, indent=2).encode())


def load_state():
    if not STATE.exists():
        raise Error('尚未接入。')
    return json.loads(STATE.read_bytes())


def discover(engine=None, config=None):
    found = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            binary = (path / 'exe').resolve(strict=True)
            name = binary.name
            if name not in ('mihomo', 'sing-box') or (engine and name != engine):
                continue
            args = (path / 'cmdline').read_bytes().decode().strip('\0').split('\0')[1:]
            if '-C' in args or '--config-directory' in args:
                continue
            flag = '-f' if name == 'mihomo' else '-c'
            long_flag = '-f' if name == 'mihomo' else '--config'
            paths = [args[i + 1] for i, a in enumerate(args[:-1]) if a in (flag, long_flag)]
            if len(paths) != 1:
                continue
            candidate = Path(paths[0])
            if not candidate.is_absolute():
                candidate = (path / 'cwd').resolve() / candidate
            if candidate.is_symlink():
                continue
            candidate = candidate.resolve()
            if config and candidate != Path(config).resolve():
                continue
            workdir = candidate.parent
            for i, arg in enumerate(args[:-1]):
                if arg in ('-d', '-D', '--directory'):
                    workdir = Path(args[i + 1])
                    if not workdir.is_absolute():
                        workdir = (path / 'cwd').resolve() / workdir
            found.append({'engine': name, 'config': str(candidate), 'binary': str(binary),
                          'workdir': str(workdir), 'pid': int(path.name)})
        except (OSError, UnicodeError):
            continue
    if len(found) != 1:
        raise Error('无法唯一识别正在运行的单文件代理；请指定 --engine 和 --config。不支持配置目录合并或容器内代理。')
    return found[0]


def manager():
    if shutil.which('rc-service'):
        return 'openrc'
    if Path('/run/systemd/system').is_dir():
        return 'systemd'
    raise Error('不支持的服务管理器。')


def service(state, action):
    args = (['rc-service', state['service'], action] if state['manager'] == 'openrc'
            else ['systemctl', action, state['service']])
    return command(args, timeout=45)


def validate(state, candidate):
    if state['engine'] == 'mihomo':
        args = [state['binary'], '-t', '-d', state['workdir'], '-f', str(candidate)]
    else:
        args = [state['binary'], 'check', '-D', state['workdir'], '-c', str(candidate)]
    command(args)


def version_check(state):
    if state['engine'] == 'sing-box':
        output = command([state['binary'], 'version'])
        match = re.search(r'version (\d+)\.(\d+)', output)
        if not match or tuple(map(int, match.groups())) < (1, 12):
            raise Error('sing-box 自动接入需要 1.12 或更新版本。')


def dependency_prepare(state, backup):
    if state['manager'] == 'openrc':
        path = Path('/etc/conf.d') / state['service']
        addition = b'\n# WARP-YUNDAN dependency\nrc_need="${rc_need} warp-yundan"\n'
    else:
        path = Path('/etc/systemd/system') / (state['service'] + '.service.d') / '80-warp-yundan.conf'
        addition = b'[Unit]\nRequires=warp-yundan.service\nAfter=warp-yundan.service\n'
        if path.exists():
            raise Error('已有同名 systemd 依赖文件，拒绝覆盖。')
    if path.is_symlink():
        raise Error('服务依赖文件是符号链接，不自动修改。')
    original = path.read_bytes() if path.exists() else None
    if original and b'WARP-YUNDAN' in original:
        raise Error('发现未登记的旧接入片段。')
    updated = (original or b'') + addition
    if original is not None:
        atomic(backup / 'dependency.original', original)
    state['dependency'] = {'path': str(path), 'existed': original is not None,
                           'before_hash': digest(original or b''), 'after_hash': digest(updated),
                           'mode': stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644}
    return path, updated


def dependency_apply(state, data):
    path = Path(state['dependency']['path'])
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic(path, data, state['dependency']['mode'])
    if state['manager'] == 'systemd':
        command(['systemctl', 'daemon-reload'])


def restore(state):
    backup = Path(state['backup'])
    config = Path(state['config'])
    # Caller has already checked that the live files are ours or the original.
    atomic(config, (backup / 'config.original').read_bytes(), state['file_mode'], state['uid'], state['gid'])
    dep = state['dependency']
    path = Path(dep['path'])
    if dep['existed']:
        atomic(path, (backup / 'dependency.original').read_bytes(), dep['mode'])
    elif path.exists():
        path.unlink()
    if state['manager'] == 'systemd':
        command(['systemctl', 'daemon-reload'])
    service(state, 'restart')
    # Do not remove fail-closed rules until the original proxy is running again.
    command([BIN, '_proxy-route-off'])
    STATE.unlink(missing_ok=True)


def check_unchanged(state):
    current = Path(state['config']).read_bytes()
    if digest(current) not in (state['before_hash'], state['after_hash']):
        raise Error('配置在接入后已被外部修改；拒绝覆盖。请从备份手动合并恢复，路由保护继续保留。')
    dep = state['dependency']
    path = Path(dep['path'])
    current = path.read_bytes() if path.exists() else b''
    if digest(current) not in (dep['before_hash'], dep['after_hash']):
        raise Error('服务依赖文件已被修改，拒绝覆盖。')


def curl_probe(state, url):
    p = state['probe']
    # Credentials travel over stdin, not argv/process listings.
    config = f'proxy = "socks5h://127.0.0.1:{p["port"]}"\nproxy-user = "warp-check:{p["password"]}"\n'
    result = subprocess.run(['curl', '-q', '--config', '-', '--noproxy', '', '-fsS',
                             '--connect-timeout', '6', '--max-time', '12', url],
                            input=config.encode(), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=16)
    if result.returncode:
        raise Error('经代理的 HTTPS 检查失败。')
    return result.stdout.decode()


def health(state):
    checks = [('IPv4', 'https://1.1.1.1/cdn-cgi/trace', True),
              ('IPv6', 'https://[2606:4700:4700::1111]/cdn-cgi/trace', state['mode'] == 'all'),
              ('域名解析', 'https://www.cloudflare.com/cdn-cgi/trace', state['mode'] == 'all')]
    # Listener start-up can lag behind the service manager's return.
    last = None
    for attempt in range(3):
        try:
            for label, url, should_warp in checks:
                trace = dict(line.split('=', 1) for line in curl_probe(state, url).splitlines() if '=' in line)
                if trace.get('warp') not in (('on', 'plus') if should_warp else ('off',)):
                    raise Error(f'{label} 的出口不符合 {state["mode"]} 模式。')
                if label == '域名解析' and state['mode'] == 'hybrid':
                    if ipaddress.ip_address(trace['ip']).version != 6:
                        raise Error('域名请求没有优先选择原生 IPv6。')
            curl_probe(state, 'https://www.google.com/generate_204')
            print('通过代理进程验证：IPv4、IPv6、域名选择与 Google HTTPS 均符合预期。')
            return
        except (Error, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
            last = exc
            if attempt < 2:
                time.sleep(1)
    raise Error('出口验证失败：' + str(last))


def attach(args):
    if STATE.exists():
        raise Error('已有接入或未完成事务。请先 proxy status / detach；不覆盖第一份备份。')
    if not (DIR / 'installed').exists():
        raise Error('WARP-YUNDAN 尚未安装。')
    state = discover(args.engine, args.config)
    state.update({'mode': args.mode, 'service': args.service or state['engine'], 'manager': manager()})
    if not re.fullmatch(r'[A-Za-z0-9_-]+', state['service']):
        raise Error('服务名仅支持字母、数字、下划线和连字符。')
    service(state, 'status' if state['manager'] == 'openrc' else 'is-active')
    version_check(state)
    path = Path(state['config'])
    if path.is_symlink() or path.stat().st_nlink != 1:
        raise Error('配置不能是符号链接或硬链接。')
    raw, data = read_config(path, state['engine'])
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    state['probe'] = {'port': port, 'password': secrets.token_hex(24)}
    updated = encode(transform(data, state['engine'], args.mode, state['probe']), state['engine'])
    print(f'识别：{state["engine"]} / {state["service"]}，模式：{args.mode}。')
    if args.dry_run:
        print('配置转换预检通过；未写入配置、未重启服务、未安装路由。正式接入还需核心与网络验证。')
        return
    backup = DIR / ('proxy-backup-' + time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3))
    backup.mkdir(mode=0o700)
    state.update({'backup': str(backup), 'before_hash': digest(raw), 'after_hash': digest(updated),
                  'file_mode': stat.S_IMODE(path.stat().st_mode), 'uid': path.stat().st_uid,
                  'gid': path.stat().st_gid, 'status': 'prepared'})
    atomic(backup / 'config.original', raw)
    candidate = backup / ('candidate.yaml' if state['engine'] == 'mihomo' else 'candidate.json')
    atomic(candidate, updated)
    _, dep_data = dependency_prepare(state, backup)
    validate(state, candidate)
    command([BIN, 'check'], timeout=35)
    if path.read_bytes() != raw:
        raise Error('预检期间配置已变更，未接入。')
    save_state(state)  # Recovery journal exists before the first production mutation.
    try:
        command([BIN, '_proxy-route-on', args.mode])
        dependency_apply(state, dep_data)
        atomic(path, updated, state['file_mode'], state['uid'], state['gid'])
        service(state, 'restart')
        # Verify the expected file is still active after the service restart.
        discover(state['engine'], state['config'])
        if path.read_bytes() != updated:
            raise Error('服务重启时改写了配置。')
        health(state)
        state['status'] = 'active'
        save_state(state)
    except BaseException:
        print('接入失败，恢复原配置及服务……', file=sys.stderr)
        try:
            check_unchanged(state)
            restore(state)
        except BaseException:
            state['status'] = 'recovery-required'
            save_state(state)
            print('自动恢复未完成；已保留备份、事务记录与路由保护，请执行 proxy detach 排查。', file=sys.stderr)
        raise
    print('接入成功。新增仅监听 127.0.0.1、带随机密码的诊断入口；备份：' + str(backup))
    print('撤销：warp-yundan proxy detach；原始配置将按字节恢复。')


def main():
    parser = argparse.ArgumentParser(description='可选接入直连出口的单文件服务端代理')
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('attach')
    p.add_argument('--mode', choices=('all', 'hybrid'), default='hybrid')
    p.add_argument('--engine', choices=('mihomo', 'sing-box'))
    p.add_argument('--config')
    p.add_argument('--service')
    p.add_argument('--dry-run', action='store_true')
    sub.add_parser('status')
    sub.add_parser('check')
    sub.add_parser('detach')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise Error('请使用 root。')
    if args.action == 'attach':
        attach(args)
    else:
        state = load_state()
        if args.action == 'status':
            print(json.dumps({k: state[k] for k in ('engine', 'mode', 'service', 'config', 'status', 'backup')}, ensure_ascii=False, indent=2))
        elif args.action == 'check':
            check_unchanged(state)
            health(state)
        else:
            check_unchanged(state)
            validate(state, Path(state['backup']) / 'config.original')
            restore(state)
            print('已恢复原配置和服务，移除代理专用路由；WARP 独立出口继续保留。备份：' + state['backup'])


if __name__ == '__main__':
    os.umask(0o077)
    def interrupted(signum, frame):
        raise Error('操作被信号中断；将尝试恢复。')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except (Error, OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.TimeoutExpired) as exc:
        # Third-party parser exceptions may include source fragments. Keep errors generic.
        print('错误：' + (str(exc) if isinstance(exc, Error) else '配置或系统操作失败，未完成接入。'), file=sys.stderr)
        sys.exit(1)
