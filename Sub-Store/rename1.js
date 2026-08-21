// name: 中文逗号分隔，如 "主节点，备用节点，测试节点"
// jump: 英文逗号分隔，如 "hk,jp" (跳过包含这些关键词的节点)

const name = decodeURI($arguments.name || '')
    .split('，')
    .filter(Boolean)
    .map(s => s.trim());

const jump = ($arguments.jump || '')
    .toLowerCase()
    .split(',')
    .filter(Boolean)
    .map(s => s.trim());

function operator(proxies) {
    let idx = 0;
    return proxies.map(p => {
        const proxy = { ...p };
        const flagMatch = proxy.name.match(/^([\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF])/);
        if (!flagMatch) return proxy;
        const flag = flagMatch[1];
        const lowerName = proxy.name.toLowerCase();
        if (jump.some(k => lowerName.includes(k))) return proxy;
        if (idx >= name.length) return proxy;
        const afterFlag = proxy.name.replace(flag, '').trim();
        const countryPart = afterFlag.replace(/\s*\d+$/, '').trim();
        proxy.name = `${flag}${countryPart} ${name[idx++]}`;
        return proxy;
    });
}
