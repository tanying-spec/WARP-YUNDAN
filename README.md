# WARP-YUNDAN

为小内存 VPS、NAT VPS、IPv6-only LXC 提供独立 Cloudflare WARP 出口。使用 Linux **内核 WireGuard**，无需额外常驻的官方 WARP 客户端。

默认**不修改原生默认路由、DNS、SSH、现有代理配置**。只有显式绑定 `wywarp` 接口的程序使用 WARP；不是安装后所有节点自动走 WARP，也不提供 SOCKS5/HTTP 监听端口。

## 一键安装

以 root 执行（需要已有 `curl`）：

```sh
curl -fL https://raw.githubusercontent.com/tanying-spec/WARP-YUNDAN/main/install.sh -o /tmp/warp-yundan-install.sh && sh /tmp/warp-yundan-install.sh install --accept-tos
```

`--accept-tos` 表示接受 [Cloudflare 服务条款](https://www.cloudflare.com/application/terms/)。不想自动接受，可先下载检查脚本。已有账号配置可以使用 `--profile` 导入，无需再次注册。

若没有 curl：Alpine 执行 `apk add curl ca-certificates`；Debian/Ubuntu 执行 `apt-get update && apt-get install -y curl ca-certificates`。

### 适用条件与限制

- 支持 Alpine/OpenRC、Debian/Ubuntu/systemd，amd64、arm64。实际验证范围见下文，未验证环境不保证兼容。
- 需要内核 WireGuard 和 `CAP_NET_ADMIN`；**存在 `/dev/net/tun` 不足以证明支持**。无法创建接口时明确退出，不会擅自加载宿主机模块。
- 注册、软件源与 GitHub 下载必须可访问。纯 IPv6 机器若无法访问 GitHub 下载域名，需已有可信 NAT64/下载通道，或从其他设备上传脚本及二进制/账号配置。WARP 尚未安装时不能替自己解决下载问题；脚本不会更换 DNS 或添加不明中转。
- IPv6-only 通过 IPv6/UDP 连接 WARP；若供应商阻断相关 UDP，脚本无法保证打通。
- IPv4 WARP 和 Google HTTPS 验证通过才算成功；IPv6 WARP 单独报告结果，不因为只有 IPv4 可用而拒绝安装。
- 不提供独立公网 IPv4 入站、端口映射、固定出口 IP 或指定出口国家。
- 内核隧道仍消耗 CPU/内存。没有额外常驻客户端不等于零开销；不保证高负载不 OOM。

## 使用与管理

```sh
warp-yundan status       # 接口、握手及流量，不打印私钥
warp-yundan check        # 实际 HTTPS 验证，IPv4 失败返回非零
warp-yundan restart     # 重建隧道，使用已验证的接入组合
curl -4 --interface wywarp https://www.cloudflare.com/cdn-cgi/trace
curl -6 --interface wywarp https://www.cloudflare.com/cdn-cgi/trace
```

返回 `warp=on` / `warp=plus` 才表示该请求使用 WARP。使用上述 curl 时域名解析仍采用系统原生 DNS；本项目不是完整 DNS 隐私方案。

持久停止或启动请使用系统服务：

```sh
# Alpine
rc-service warp-yundan stop
rc-service warp-yundan start
# Debian / Ubuntu
systemctl stop warp-yundan
systemctl start warp-yundan
```

安装后默认开机启动。只想暂停跨重启启动时，使用 `rc-update del warp-yundan default` 或 `systemctl disable warp-yundan`。

## 工作方式

1. 安装最少依赖，注册独立账号，或复用本项目已有账号。
2. 当前固定使用上游 `wgcf 2.2.31` 并校验官方 SHA-256；选择此版是因为验证时 2.2.32 注册返回 HTTP 429。旧版也不保证未来始终可注册。
3. 对有路由的 IPv6/IPv4 接入点分别尝试 UDP `2408`、`500`、`4500`；尝试随机本地端口及 `38386`。没有可达性保证，不进行大规模扫描。
4. 每个组合新建接口，检查 WARP trace 和 Google `generate_204`。成功后记录实际本地端口，再重建验证，避免沿用旧握手误判。
5. 使用独立路由表 `51889` 和规则优先级 `18589`，只匹配 `oif wywarp`。发现接口、路由表或规则冲突时拒绝覆盖。
6. 最后设置系统服务并再次检查。失败清理本次隧道并取消本项目开机启动，保留私密账号便于排查。

启动服务仅恢复已验证组合，不会每次开机注册或自动更换 IP。没有自动测速、账号轮换或持续健康监控。

## 导入已有配置 / 离线二进制

```sh
sh /tmp/warp-yundan-install.sh install --profile /root/wgcf-profile.conf
```

支持标准 wgcf/WireGuard 单 peer 配置；不会执行 `PostUp` 等配置钩子。导入的 `Endpoint`、`ListenPort` 被自动检测结果取代。不要让同一 WARP 身份同时在多个隧道上运行，可能互相影响。

```sh
sh /tmp/warp-yundan-install.sh install --accept-tos --wgcf /root/wgcf_2.2.31_linux_amd64
```

上传二进制仍会校验版本对应 SHA-256。需要独立上传脚本的机器请把命令中的脚本路径替换成实际路径。

## 卸载 / 重装

```sh
warp-yundan uninstall
```

卸载移除本项目接口、规则、服务和管理命令；**保留 `/etc/warp-yundan` 内账号，权限仅限 root**。重跑安装命令可复用。系统依赖不卸载，避免影响其他应用。若要彻底销毁账号文件，应在确认不再需要后手动删除该目录；本地删除不会注销 Cloudflare 账号。

私钥、账号及日志都不得上传 GitHub。本仓库没有共享 WARP 凭据。

## 验证与故障排查

- CI：POSIX shell 语法、ShellCheck、隔离网络命名空间内的路由/冲突/清理回归测试。
- 已在 Alpine 3.23 / amd64 / 小内存 LXC 上验证完整安装、IPv6 接入后的 WARP 双栈访问、服务重启、重复安装、卸载和原生路由恢复；使用已有账号导入/复用。注册工具 2.2.31 已在同一环境单独成功注册。
- Debian/Ubuntu 的 systemd 服务流程及 arm64 尚未实机验证；CI 测试不能替代这些实机测试。未测试整机重启，仅测试服务重启和开机启动项。
- 短时测试不代表长期稳定或完整带宽性能。
- HTTP 429：可能是注册接口限制或客户端兼容问题；日志保存在 `/etc/warp-yundan/register.log`，不要公开其全部内容。
- 所有候选失败：检查宿主机 UDP 限制、账号有效性及原生网络，不代表换同类客户端必然解决。
- 无法访问 Google 的网络/地区会让验证失败，即使某些其他网站可访问。这是有意采用的保守验证标准。

## 来源

账号注册工具：[ViRb3/wgcf](https://github.com/ViRb3/wgcf)（非官方工具）；隧道：[WireGuard](https://www.wireguard.com/)；网络服务：[Cloudflare WARP](https://one.one.one.one/)。本项目与这些项目及公司无隶属关系，不包含其二进制文件。
