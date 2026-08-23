import { definePlugin, jsonResponse, server } from "@komari-monitor/plugin-sdk";

// Node.js modules are provided by Komari when the `node` permission is enabled.
const fs = require("fs");
const path = require("path");

interface PluginConfig {
  interval?: number;
  notify?: boolean;
  template?: string;
  nodes?: string[] | string;
  // Number of consecutive checks that must report the same new IP before it
  // is accepted as a real change (debounce against DNS-unlock flapping).
  confirm_count?: number;
}

interface IpState {
  node_uuid: string;
  node_name: string;
  ip_version: "ipv4" | "ipv6";
  last_ip: string;
  last_checked_at: string;
  last_changed_at?: string;
  // Pending candidate IP that differs from last_ip but has not been observed
  // enough consecutive times yet.
  pending_ip?: string;
  pending_count?: number;
}

interface IpChange {
  node: any;
  version: "ipv4" | "ipv6";
  oldIp: string;
  newIp: string;
}

const STORAGE_FILE = path.join(__storageDir__, "state.json");
const DEFAULT_TEMPLATE = "出口 IP 发生变化：{{node}} {{ip_version}} {{old_ip}} -> {{new_ip}}";
const DEFAULT_INTERVAL = 5;
const DEFAULT_CONFIRM_COUNT = 2;

function loadState(): Record<string, IpState> {
  try {
    if (!fs.existsSync(STORAGE_FILE)) return {};
    const value = JSON.parse(fs.readFileSync(STORAGE_FILE, "utf8"));
    return value && typeof value === "object" ? value : {};
  } catch (error) {
    console.error("[ip-change] failed to load state:", error);
    return {};
  }
}

function saveState(state: Record<string, IpState>): void {
  try {
    fs.writeFileSync(STORAGE_FILE, JSON.stringify(state, null, 2));
  } catch (error) {
    console.error("[ip-change] failed to save state:", error);
  }
}

function selectedNodeUuids(config: PluginConfig): Set<string> | null {
  if (config.nodes == null || config.nodes === "") return null;
  const values = Array.isArray(config.nodes)
    ? config.nodes
    : String(config.nodes)
        .split(/[\s,]+/)
        .filter(Boolean);
  return values.length ? new Set(values.map(String)) : null;
}

function nodeIp(node: any, version: "ipv4" | "ipv6"): string {
  const value = version === "ipv4"
    ? node && (node.ipv4 ?? node.public_ipv4)
    : node && (node.ipv6 ?? node.public_ipv6);
  return typeof value === "string" ? value.trim() : "";
}

function nodeEntries(nodes: Record<string, any> | any[]): Array<{ uuid: string; node: any }> {
  if (Array.isArray(nodes)) {
    return nodes.map((node: any) => ({
      uuid: String(node && (node.uuid || node.id) || ""),
      node,
    })).filter((entry) => entry.uuid);
  }
  return Object.keys(nodes || {}).map((uuid) => ({ uuid, node: nodes[uuid] }));
}

function formatTime(): string {
  return new Date().toLocaleString("zh-CN", { hour12: false });
}

function renderTemplate(template: string, change: IpChange): string {
  const name = String(change.node && (change.node.name || change.node.hostname) || change.node.uuid || "未知节点");
  const values: Record<string, string> = {
    node: name,
    node_id: String(change.node && (change.node.uuid || change.node.id) || ""),
    old_ip: change.oldIp || "未知",
    new_ip: change.newIp,
    ip_version: change.version.toUpperCase(),
    time: formatTime(),
  };
  // Komari templates use double braces. Keep single-brace replacement for
  // templates saved by the earlier version of this plugin.
  return template.replace(/\{\{([a-zA-Z0-9_]+)\}\}|\{([a-zA-Z0-9_]+)\}/g, (all, doubleKey, singleKey) => {
    const key = String(doubleKey || singleKey).toLowerCase();
    return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : all;
  });
}

async function sendNotification(config: PluginConfig, change: IpChange): Promise<void> {
  if (config.notify === false) return;
  const configured = typeof config.template === "string" && config.template.trim()
    ? config.template.trim()
    : DEFAULT_TEMPLATE;
  const message = renderTemplate(configured, change);
  try {
    await server.call("admin:sendNotification", {
      event: {
        event: "IP_CHANGE",
        emoji: "🌐",
        message,
        time: new Date().toISOString(),
        clients: [{ uuid: String(change.node.uuid || change.node.id || "") }],
      },
    });
  } catch (error) {
    console.warn("[ip-change] notification failed:", error);
  }
}

async function checkOnce(): Promise<Record<string, any>> {
  const config = (await server.getConfig()) as PluginConfig;
  const nodes = (await server.call("common:getNodes")) as Record<string, any> | any[];
  const selected = selectedNodeUuids(config);
  const state = loadState();
  const changes: IpChange[] = [];
  const checkedAt = new Date().toISOString();
  const confirmCount = Math.max(1, Math.floor(Number(config.confirm_count) || DEFAULT_CONFIRM_COUNT));
  let checked = 0;

  for (const { uuid, node } of nodeEntries(nodes)) {
    if (selected && !selected.has(uuid)) continue;
    // An offline node's last reported address is still useful; only notify when
    // Komari has actually reported a new non-empty address.
    for (const version of ["ipv4", "ipv6"] as const) {
      const ip = nodeIp(node, version);
      if (!ip) continue;
      checked++;
      const key = `${uuid}#${version}`;
      const previous = state[key];
      const entry: IpState = {
        node_uuid: uuid,
        node_name: String(node && (node.name || node.hostname) || uuid),
        ip_version: version,
        last_ip: previous?.last_ip || ip,
        last_checked_at: checkedAt,
        last_changed_at: previous?.last_changed_at,
      };
      if (!previous || !previous.last_ip || ip === previous.last_ip) {
        // First sighting or same IP: accept immediately and clear any pending
        // candidate (the flap resolved itself back to the recorded IP).
        entry.last_ip = ip;
        if (!previous || !previous.last_ip) entry.last_changed_at = checkedAt;
      } else if (ip !== previous.last_ip) {
        // Candidate differs from the recorded IP: require it to be seen
        // confirm_count consecutive times before accepting it as a change.
        const pendingCount = previous.pending_ip === ip ? (previous.pending_count || 0) + 1 : 1;
        if (pendingCount >= confirmCount) {
          entry.last_ip = ip;
          entry.last_changed_at = checkedAt;
          changes.push({ node: { ...node, uuid }, version, oldIp: previous.last_ip, newIp: ip });
        } else {
          entry.pending_ip = ip;
          entry.pending_count = pendingCount;
        }
      }
      state[key] = entry;
    }
  }
  saveState(state);
  for (const change of changes) await sendNotification(config, change);
  return { ok: true, checked, changes: changes.map((change) => ({
    node: String(change.node.name || change.node.uuid),
    node_id: String(change.node.uuid),
    ip_version: change.version,
    old_ip: change.oldIp,
    new_ip: change.newIp,
  })) };
}

function cronExpression(minutes: number): string {
  const value = Math.max(1, Math.min(59, Math.floor(Number(minutes) || DEFAULT_INTERVAL)));
  return `*/${value} * * * *`;
}

function isAdmin(req: any): boolean {
  const principal = req && req.context && req.context.principal;
  const roles: string[] = principal && principal.roles || [];
  return !!principal && principal.type === "user" && roles.includes("admin");
}

definePlugin({
  load() {
    server.getConfig().then((config: PluginConfig) => {
      server.cron(cronExpression(config.interval || DEFAULT_INTERVAL), () => {
        checkOnce().catch((error) => console.error("[ip-change] check failed:", error));
      });
      console.log(`[ip-change] scheduled check every ${config.interval || DEFAULT_INTERVAL} minute(s)`);
    }).catch((error) => console.error("[ip-change] failed to load config:", error));

    server.route("GET", "/ip-change/status", (req: any, res: any) => {
      if (!isAdmin(req)) { res.statusCode = 401; res.end("unauthorized"); return; }
      jsonResponse(res, loadState());
    });

    server.route("POST", "/ip-change/check", async (req: any, res: any) => {
      if (!isAdmin(req)) { res.statusCode = 401; res.end("unauthorized"); return; }
      try { jsonResponse(res, await checkOnce()); }
      catch (error) { jsonResponse(res, { ok: false, error: String(error) }, 500); }
    });
  },
});
