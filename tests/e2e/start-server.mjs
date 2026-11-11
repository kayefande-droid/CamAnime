// Boots the real Flask app for end-to-end tests on a throwaway database.
// Cookies are Secure in production, so they must be relaxed for plain-HTTP
// localhost or the browser silently drops the session cookie.
import { spawn } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();
const dbDir = join(root, ".e2e");
mkdirSync(dbDir, { recursive: true });
rmSync(join(dbDir, "e2e.db"), { force: true });

const python =
  process.env.E2E_PYTHON ||
  (process.platform === "win32" ? ".venv/Scripts/python.exe" : ".venv/bin/python");

// Port 5055 keeps the suite clear of a developer's own server on 3000.
const port = process.env.E2E_PORT || "5055";
const child = spawn(python, ["-c", `import app; app.app.run(host="127.0.0.1", port=${port}, threaded=True)`], {
  cwd: root,
  stdio: "inherit",
  env: {
    ...process.env,
    CAMANIME_DB: join(dbDir, "e2e.db"),
    CAMANIME_SECRET: "e2e-only-not-production",
    CAMANIME_COOKIE_SECURE: "0",
    CAMANIME_ADMIN_EMAIL: "e2e-owner@example.com",
    CAMANIME_ADMIN_PASSWORD: "e2e-owner-password",
    PYTHONIOENCODING: "utf-8",
  },
});

const stop = () => {
  child.kill("SIGTERM");
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
child.on("exit", (code) => process.exit(code ?? 0));
