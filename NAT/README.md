# NAT 运维与代理脚本

用于 NAT / VPS 服务器的端口转发与代理管理脚本集合。

## 脚本列表

### 1. EZrealm.sh
- **修改自**：[qqrrooty/EZrealm](https://github.com/qqrrooty/EZrealm)
- **修改说明**：
  - 新增 Alpine Linux 环境自检测与自举支持，并兼容 OpenRC / systemd 双服务管理系统；
  - 新增对 Musl libc 与 GNU libc 识别，扩展多 CPU 架构支持（x86_64、aarch64、armv7 等）；
  - 优化 TOML 配置解析，采用 awk 精确匹配 `[[endpoints]]` 块，支持备注并修复规则展示与删除索引错位问题；
  - 改进定时任务管理（兼容 `/etc/crontab` 与用户级 crontab）与交互菜单。
- **功能说明**：基于 Realm 的端口转发管理脚本，支持快速添加、修改及查看端口转发规则。
- **运行命令**：
```bash
wget -N https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/NAT/EZrealm.sh && chmod +x EZrealm.sh && ./EZrealm.sh
```

### 2. singbox-lite.sh
- **修改自**：[0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite)
- **修改说明**：修复 AnyTls 报错与超时问题。
- **功能说明**：Sing-box 轻量级多功能管理脚本，特别针对小内存 / NAT VPS 环境深度优化，支持多协议节点配置与中继转发，安装后提供 `sb` 快捷交互菜单。
- **运行命令**：
```bash
wget -q https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/NAT/singbox-lite.sh -O /usr/local/bin/sb && chmod +x /usr/local/bin/sb && sb
```

### 3. vless-enc.sh
- **修改自**：[yahuisme/vless-encryption](https://github.com/yahuisme/vless-encryption)
- **修改说明**：
  - 新增 Alpine Linux 环境自检测与 apk 依赖自举支持；
  - 自动适配 OpenRC (`/etc/init.d/xray`) 与 systemd 双 Init 服务管理系统；
  - 完善 Xray 核心下载校验、服务生命周期管理、快照备份与回滚机制；
  - 适配 Alpine/OpenRC 下的日志查看与服务状态展示。
- **功能说明**：Xray VLESS Encryption 极简一键安装与管理脚本，支持 VLESS Encryption 及 VLESS Encryption + REALITY（XTLS Vision 流控与 ML-KEM-768 后量子认证），提供交互式菜单与非交互命令行参数。
- **运行命令**：
```bash
wget -N https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/NAT/vless-enc.sh && chmod +x vless-enc.sh && ./vless-enc.sh
```


