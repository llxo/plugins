# Komari 出口 IP 变化通知插件

修改自 https://github.com/yunjianj/Komari-DDNS/

插件按设定间隔读取 Komari 节点上报的公网 IPv4/IPv6 地址，保存上次结果。地址发生变化时发送一条 Komari 通知

当前版本 1.4 可在 `Komari/dist` 下载

## 配置

| 配置 | 说明 |
| --- | --- |
| `interval` | 检查间隔（分钟，默认 5） |
| `nodes` | 要监控的节点；留空表示全部节点 |
| `notify` | 是否发送通知（默认开启） |
| `template` | 通知正文模板（富文本输入框） |

模板使用双大括号占位符，支持以下变量：

| 占位符 | 内容 |
| --- | --- |
| `{{node}}` | 节点名称 |
| `{{node_id}}` | 节点 UUID |
| `{{old_ip}}` | 变化前的地址；首次建立基线时不会通知 |
| `{{new_ip}}` | 变化后的地址 |
| `{{ip_version}}` | `IPV4` 或 `IPV6` |
| `{{time}}` | 本地时间 |

默认模板为：

```text
出口 IP 发生变化：{{node}} {{ip_version}} {{old_ip}} -> {{new_ip}}
```

状态保存在插件长期存储目录的 `state.json` 中。插件启用或重启后的第一次检查只建立基线，避免产生误报。

## 开发

```sh
npm install
npm run typecheck
npm run build
npm run pack
```

插件需要 `node`、`allowSystemRPC` 和 `allowRoutes` 权限，分别用于保存状态、读取节点并发送通知，以及提供管理员状态/手动检查接口：

- `GET /ip-change/status`
- `POST /ip-change/check`
