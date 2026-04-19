import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import electron from "electron";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const screenshotDir = path.join(repoRoot, "docs", "screenshots");
const electronBinary = String(electron || "");
const requiredShots = [
  "dashboard.png",
  "configure.png",
  "wizard.png"
];

function fail(message) {
  console.error(`[screenshots] ${message}`);
  process.exit(1);
}

if (!electronBinary || !fs.existsSync(electronBinary)) {
  fail(`Electron binary not found at ${electronBinary}. Run "npm install --package-lock=false" first.`);
}

fs.mkdirSync(screenshotDir, { recursive: true });

const child = spawn(
  electronBinary,
  [".", "--capture-screenshots", `--screenshot-dir=${screenshotDir}`],
  {
    cwd: repoRoot,
    stdio: "inherit"
  }
);

child.once("error", (error) => {
  fail(`Failed to launch Electron: ${error?.message || error}`);
});

child.once("exit", (code) => {
  if (code !== 0) {
    fail(`Electron exited with code ${code}.`);
  }

  const missingShots = requiredShots.filter((fileName) => {
    try {
      return fs.statSync(path.join(screenshotDir, fileName)).size <= 0;
    } catch {
      return true;
    }
  });

  if (missingShots.length > 0) {
    fail(`Missing or empty screenshot files: ${missingShots.join(", ")}`);
  }

  console.log(`[screenshots] Completed: ${requiredShots.join(", ")}`);
});
