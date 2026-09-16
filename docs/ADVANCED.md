# 高级使用

普通使用只需运行 `wy`。本页面面向需要自动化、离线安装或明确指定代理配置的用户。

## 参数化代理接入

```sh
warp-yundan proxy attach --mode hybrid
warp-yundan proxy attach --mode all
warp-yundan proxy status
warp-yundan proxy check
warp-yundan proxy detach
```

存在多个实例时可明确指定：

```sh
warp-yundan proxy attach --mode hybrid --engine mihomo \
  --config /etc/mihomo/config.yaml --service mihomo

warp-yundan proxy attach --mode hybrid --engine sing-box \
  --config /etc/sing-box/config.json --service sing-box
```

只转换并检查配置结构，不写入或重启：

```sh
warp-yundan proxy attach --mode hybrid --dry-run
```

Mihomo 需要 `rule` 模式和明确的 MATCH/FINAL 规则。sing-box 需要 1.12+ 标准 JSON 单文件。配置目录合并、容器内代理、TUN/redirect/tproxy、远端代理链、动态 provider、已有接口绑定或路由标记不自动支持。

## 导入已有 WARP 配置

```sh
sh /tmp/warp-yundan-install.sh install --profile /root/wgcf-profile.conf
```

只读取标准 WireGuard 单 peer 数据，不执行 `PostUp`、`PreUp` 等钩子。Endpoint 和 ListenPort 会由连接测试重新选择。

## 离线提供 wgcf

```sh
sh /tmp/warp-yundan-install.sh install --accept-tos \
  --wgcf /root/wgcf_2.2.31_linux_amd64
```

上传的二进制仍必须匹配脚本内置 SHA-256。代理接入模块需要 Python3 和 PyYAML，按需安装，不常驻。

## 系统服务

```sh
# Alpine
rc-service warp-yundan start
rc-service warp-yundan stop

# Debian / Ubuntu
systemctl start warp-yundan
systemctl stop warp-yundan
```

卸载会移除接口、规则、服务和命令，但保留 `/etc/warp-yundan` 中的账号，便于重装。接入代理期间必须先执行 `proxy detach`。
