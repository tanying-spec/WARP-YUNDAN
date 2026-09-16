# WARP-YUNDAN

面向小内存 VPS、NAT VPS 和 IPv6-only LXC 的轻量 Cloudflare WARP 出口。使用 Linux 内核 WireGuard，没有常驻 WARP 客户端。

默认不修改系统默认路由、DNS、SSH 或现有代理。只有明确绑定 `wywarp` 的流量使用 WARP；通过菜单可选择让 Mihomo / sing-box 的直连出口使用 WARP。

## 一键安装

以 root 执行：

```sh
curl -fL https://raw.githubusercontent.com/tanying-spec/WARP-YUNDAN/main/install.sh -o /tmp/warp-yundan-install.sh && sh /tmp/warp-yundan-install.sh install --accept-tos
```

`--accept-tos` 表示接受 [Cloudflare 服务条款](https://www.cloudflare.com/application/terms/)。安装需要可访问 GitHub、软件源和 Cloudflare 注册服务。

支持：

- Alpine / OpenRC、Debian / Ubuntu / systemd
- amd64、arm64
- 内核 WireGuard 和 `CAP_NET_ADMIN`
- IPv4、双栈或具有可用 IPv6/UDP 的 IPv6-only 网络

安装器发现使用相同 WARP 身份的旧 WireGuard 接口时会停止，不会自动关闭或覆盖旧服务。

## 使用

安装后只需记住：

```sh
wy
```

统一菜单可以：

1. 查看 WARP、出口地区、握手、开机启动和代理接入状态。
2. 执行 IPv4 / IPv6 WARP 与 HTTPS 检查。
3. 接入、检查或撤销 Mihomo / sing-box。
4. 重启 WARP。
5. 查看 WireGuard 原始状态。

### 代理接入模式

- `hybrid`：域名优先使用原生 IPv6，IPv4 直连出口使用 WARP。适合 IPv6-only/NAT 小鸡。
- `all`：代理的 IPv4、IPv6 直连出口都使用 WARP。

代理接入是可选功能。系统管理流量和 SSH 不会被接管；接入前会备份配置，失败自动回滚，WARP 断线时标记流量不会泄漏到原生出口。

## 常用命令

```sh
wy                         # 统一菜单
warp-yundan status         # 简洁状态
warp-yundan check          # 完整连通性检查
warp-yundan restart        # 重启隧道
warp-yundan status-raw     # WireGuard 原始状态
warp-yundan uninstall      # 卸载程序，保留账号文件
```

已有安装重新执行一键安装命令即可更新，账号、隧道参数和代理接入状态会保留。

## 重要限制

- 不提供公网 IPv4 入站、端口映射、固定出口 IP 或指定出口国家。
- 代理自动接入只支持单文件、直连出口的 Mihomo / sing-box；TUN、远端代理链、动态 provider 和面板生成配置会被拒绝。
- 不要让同一 WARP 账号同时运行在多个 WireGuard 接口上。
- 私钥、账号文件及完整日志不得上传 GitHub。
- Debian/Ubuntu systemd 与 arm64 尚未完成同等强度的实机验证，详见高级文档。

## 详细文档

- [高级使用](docs/ADVANCED.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [安全与回滚](docs/SECURITY.md)
- [工作原理](docs/HOW-IT-WORKS.md)
- [版本记录](CHANGELOG.md)

## 来源

账号工具：[ViRb3/wgcf](https://github.com/ViRb3/wgcf)；隧道：[WireGuard](https://www.wireguard.com/)；网络服务：[Cloudflare WARP](https://one.one.one.one/)。本项目与上述项目及公司无隶属关系，不包含其二进制文件。
