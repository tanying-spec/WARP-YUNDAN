# 工作原理

## 独立 WARP 出口

项目使用内核 WireGuard 创建 `wywarp`，并将 WARP 的 IPv4/IPv6 默认路由放入独立表 `51889`。规则只匹配 `oif wywarp`，不修改 main 表默认路由。

安装阶段会注册或导入账号、校验 wgcf、尝试 Cloudflare Endpoint 与 UDP 端口、检查 WARP trace 和 HTTPS、记录通过验证的组合，最后创建 OpenRC/systemd oneshot 服务。

启动服务只恢复已验证组合，不会重新注册、自动测速或轮换账号。

## hybrid

Mihomo direct 出站使用 `ipv6-prefer`，sing-box direct 使用 `prefer_ipv6`。IPv4 套接字添加标记并查表 `51890` 进入 WARP；IPv6 优先使用原生网络。

客户端已经提交 IPv4 字面地址时不存在可重新解析的域名，因此仍会走 WARP。

## all

代理 direct 出站的 IPv4、IPv6 套接字都添加标记，通过 `wywarp` 出口。系统中未标记的流量仍使用原生网络。

## 状态和验证

`status` 提供服务、开机启动、握手、IPv4/IPv6 WARP trace 和代理状态摘要。`check` 执行更严格的 WARP 与 HTTPS 检查。`status-raw` 保留完整 `wg show` 输出。

CI 使用 ShellCheck、Python 单元测试和隔离网络命名空间验证路由范围、冲突拒绝、WARP 消失时的防泄漏及清理行为。
