const fs = require("fs");
const path = require("path");

const pkg = require(path.join(__dirname, "..", "package.json"));
const v = pkg.version;
const dir = path.join(__dirname, "..", "dist");
const oldName = `ip-change-${v}.zip`;
const newName = `komari-ip-change-${v}.zip`;
const oldPath = path.join(dir, oldName);
const newPath = path.join(dir, newName);

function safeUnlink(p) {
  try {
    if (fs.existsSync(p)) fs.unlinkSync(p);
  } catch (e) {
    console.warn(`[rename] 无法删除 ${p}（可能被占用）：${e.message}`);
  }
}

if (!fs.existsSync(oldPath)) {
  console.log(`skip rename: ${oldName} not found in dist/`);
  process.exit(0);
}

// Prefer a clean rename; fall back to copy if the target is locked.
safeUnlink(newPath);
try {
  fs.renameSync(oldPath, newPath);
} catch (e) {
  console.warn(`[rename] rename 失败，尝试 copy：${e.message}`);
  fs.copyFileSync(oldPath, newPath);
  safeUnlink(oldPath);
}

if (fs.existsSync(newPath)) {
  console.log(`pack -> ${path.join("dist", newName)}`);
} else {
  console.error(`rename 失败：${newName} 未生成，请手动处理 dist/${oldName}`);
  process.exit(1);
}
