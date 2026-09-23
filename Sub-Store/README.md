# Sub-Store 脚本集合

用于 Sub-Store 订阅管理器的节点操作与处理脚本。

## 脚本说明

### 1. rename0.js
- **说明**：节点名称规则化与标准化重命名脚本，支持国家地区识别、国旗/中英文/ISO 3166-1 Alpha-3 三字母代码转换及序号格式化。
- **链接**：
```
https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/Sub-Store/rename0.js
```

### 2. rename1.js
- **说明**：自定义序列重命名脚本，支持按自定义名称列表批量重命名节点并过滤/跳过特定关键词节点。
- **链接**：
```
https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/Sub-Store/rename1.js
```

### 3. singbox-pubkey-sha256.js
- **说明**：Sing-box 证书公钥 SHA256 注入脚本，为开启跳过证书校验的节点配置公钥哈希以增强连接安全性。
- **链接**：
```
https://raw.githubusercontent.com/llxo/plugins/refs/heads/main/Sub-Store/singbox-pubkey-sha256.js
```
