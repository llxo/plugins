/**
 * 用法：Sub-Store 脚本操作
 *
 * 参数格式示例：
 * 1. JSON 键值对映射（推荐）：
 *    {"香港 01": "hash1", "日本 02": "hash2"}
 *    或 data={"香港 01": "hash1", "日本 02": "hash2"}
 *
 * 2. 传统逗号传参：
 *    sha256=hash1,hash2&tag=香港 01,日本 02
 */

function operator(proxies = [], targetPlatform) {
    const rawArgs = typeof $arguments !== 'undefined' && $arguments ? $arguments : {};

    const safeDecode = (str) => {
        try { return decodeURIComponent(str); } catch (e) { return str; }
    };

    let mappingRules = [];
    let fallbackHashes = [];

    let jsonStr = null;
    if (typeof rawArgs === 'string' && rawArgs.trim().startsWith('{')) {
        jsonStr = rawArgs.trim();
    } else if (rawArgs && typeof rawArgs.data === 'string') {
        jsonStr = rawArgs.data.trim();
    } else if (rawArgs && typeof rawArgs.data === 'object') {
        for (const [tag, hash] of Object.entries(rawArgs.data)) {
            if (hash) mappingRules.push({ tag: String(tag).trim(), hash: String(hash).trim() });
        }
    }

    if (jsonStr) {
        try {
            const parsed = JSON.parse(safeDecode(jsonStr));
            for (const [tag, hash] of Object.entries(parsed)) {
                if (hash) {
                    mappingRules.push({ tag: String(tag).trim(), hash: String(hash).trim() });
                }
            }
        } catch (e) {}
    }

    if (mappingRules.length === 0) {
        const sha256List = `${rawArgs.sha256 || ''}`
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean);

        const tagList = safeDecode(`${rawArgs.tag || ''}`)
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean);

        if (tagList.length > 0) {
            tagList.forEach((tag, idx) => {
                if (sha256List[idx]) {
                    mappingRules.push({ tag, hash: sha256List[idx] });
                }
            });
        } else {
            fallbackHashes = sha256List;
        }
    }

    let fallbackIndex = 0;

    for (const proxy of proxies) {
        if (!proxy || typeof proxy !== 'object') continue;

        const proxyName = proxy.name || proxy.tag || '';
        let matchedHash = null;

        if (mappingRules.length > 0) {
            let found = mappingRules.find((r) => r.tag === proxyName);
            if (!found) {
                found = mappingRules.find((r) => proxyName.includes(r.tag) || r.tag.includes(proxyName));
            }
            if (found) {
                matchedHash = found.hash;
            }
        } else if (fallbackIndex < fallbackHashes.length) {
            if (proxy.insecure || proxy['skip-cert-verify']) {
                matchedHash = fallbackHashes[fallbackIndex++];
            }
        }

        if (matchedHash) {
            delete proxy['skip-cert-verify'];
            delete proxy.insecure;

            proxy._certificate_public_key_sha256 = [matchedHash];
            if (proxy.tls && typeof proxy.tls === 'object') {
                proxy.tls.certificate_public_key_sha256 = [matchedHash];
            }
        }
    }

    return proxies;
}
