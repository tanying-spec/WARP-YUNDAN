# 更新记录

## v1.1.1

- 新增两字母短命令 `wy`，无参数运行直接进入代理接入菜单；原有 `warp-yundan` 命令保持兼容。
- 安装和升级时仅在 `/usr/local/sbin/wy` 未被占用时创建链接，卸载时只删除本项目拥有的链接。

## v1.1.0

- 增加可选 `proxy attach/status/check/detach`，支持 Mihomo / sing-box 单文件直连出口服务端配置。
- `hybrid` 使用原生 IPv6 优先＋WARP IPv4；`all` 使用 WARP 双栈出口。原生系统默认路由不变。
- 原始配置备份、核心配置预检、原子替换、通过代理的 HTTPS 检查及失败回滚。
- OpenRC/systemd 启动依赖、WARP 停止后禁止标记流量回落、外部配置变更保护。
- 新增带密码的本地诊断入口，撤销时随原配置恢复而移除。
- 已安装版本重新运行安装命令时更新管理脚本，不重新注册账号。
- Alpine 3.23 amd64 LXC：Mihomo 1.19.30 与 sing-box 1.14.1 musl 的 hybrid / all 接入、HTTPS 检查及撤销均通过实测。生产代理配置未改动。
- 增加交互式 `warp-yundan proxy` 菜单；无参数运行也进入代理接入菜单，原有参数化命令继续可用。

## v1.0.0

- 内核 WireGuard 独立出口，原生路由、DNS、现有代理不变。
- 自动测试 IPv6/IPv4 接入与有限端口组合，保存已验证组合。
- 独立账号注册、官方 wgcf 文件 SHA-256 校验、已有配置导入。
- WARP trace 与外站 HTTPS 双重验证，重建后复核。
- Alpine/OpenRC、Debian/Ubuntu/systemd 启动配置。
- 冲突拒绝、失败清理、重复安装复用、保留账号卸载。
