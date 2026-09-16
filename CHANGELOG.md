# 更新记录

## v1.0.0

- 内核 WireGuard 独立出口，原生路由、DNS、现有代理不变。
- 自动测试 IPv6/IPv4 接入与有限端口组合，保存已验证组合。
- 独立账号注册、官方 wgcf 文件 SHA-256 校验、已有配置导入。
- WARP trace 与外站 HTTPS 双重验证，重建后复核。
- Alpine/OpenRC、Debian/Ubuntu/systemd 启动配置。
- 冲突拒绝、失败清理、重复安装复用、保留账号卸载。
