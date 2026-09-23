/**
 * 用法：Sub-Store 脚本操作
 *
 * 参数说明：
 * sha256: 证书公钥 SHA256 哈希值，多个值使用英文逗号 (,) 分隔。
 *         示例：sha256=hash1,hash2
 *
 * 逻辑说明：
 * 遍历节点，若节点配置了 insecure 或 skip-cert-verify，则将其移除，
 * 并按顺序依次为节点注入 _certificate_public_key_sha256 公钥哈希进行固定证书校验。
 */

function operator(proxies = [], targetPlatform) {
    const raw = typeof $arguments !== 'undefined' && $arguments ? $arguments.sha256 : '';
    const sha256List = `${raw || ''}`
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);

    let index = 0;

    for (const proxy of proxies) {
        if (proxy.insecure || proxy['skip-cert-verify']) {
            delete proxy['skip-cert-verify'];
            delete proxy.insecure;

            if (index < sha256List.length) {
                const currentHash = sha256List[index];
                proxy._certificate_public_key_sha256 = Array.isArray(currentHash)
                    ? currentHash
                    : [currentHash];
                index++;
            }
        }
    }

    return proxies;
}
