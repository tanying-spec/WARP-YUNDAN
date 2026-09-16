# 故障排查

先运行 `wy`，选择“查看状态”和“检查 WARP”。需要原始 WireGuard 信息时选择菜单第 5 项。

## 发现旧 WARP 接口

安装器检测到其他 WireGuard 接口使用相同 WARP 公钥时会拒绝启动。先确认旧服务归属，再停止并禁用；脚本不会自动修改未知服务。

常见旧服务名包括 `warp`、`wgcf`、`wgcf-wg`，但不能仅凭名称删除。应先查看：

```sh
wg show
ip -brief address
```

## 无法创建接口

存在 `/dev/net/tun` 不代表具备内核 WireGuard 或 `CAP_NET_ADMIN`。LXC 需要宿主机提供 WireGuard 并授予网络管理能力。

## 所有候选接入失败

检查原生 IPv6/IPv4 路由、供应商 UDP 2408/500/4500 限制、WARP 账号、DNS、GitHub、Cloudflare 注册服务和软件源。

注册 HTTP 429 可能来自接口限制或客户端兼容问题。详细日志位于 `/etc/warp-yundan/register.log`，不要公开完整内容。

## WARP 正常但代理没有使用

独立安装不会自动接管 Mihomo/sing-box。运行 `wy`，选择“管理代理接入”。状态显示“代理：未接入”时，普通代理流量仍使用原生出口。

## 代理接入失败

脚本会尝试恢复原配置。若检测到配置被外部程序修改，会拒绝覆盖。事务状态、脱敏错误提示和 root-only 备份保存在 `/etc/warp-yundan`。

面板动态生成配置、TUN、远端代理链和复杂自定义 DNS 不应强行接入。

## 测试范围

Alpine 3.23 amd64 小内存 LXC 已验证安装、双栈 WARP、服务重启、重复安装、卸载、Mihomo/sing-box 接入与恢复。Debian/Ubuntu systemd、arm64 和长期满负载尚未完成同等强度的实机验证。
