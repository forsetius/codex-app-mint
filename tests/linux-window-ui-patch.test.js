#!/usr/bin/env node

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const repoDir = path.resolve(__dirname, "..");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-window-ui-test-"));

try {
  const assetsDir = path.join(tempDir, "webview", "assets");
  const buildDir = path.join(tempDir, ".vite", "build");
  fs.mkdirSync(assetsDir, { recursive: true });
  fs.mkdirSync(buildDir, { recursive: true });
  fs.writeFileSync(path.join(assetsDir, "app-test.png"), "fake png", "utf8");

  const bundlePath = path.join(buildDir, "main-test.js");
  fs.writeFileSync(
    bundlePath,
    [
      "function f5(e){return e===`avatarOverlay`||e===`browserCommentPopup`||e===`globalDictation`||e===`hotkeyWindowHome`||e===`hotkeyWindowThread`}",
      "shouldAlwaysUseOpaqueWindowSurface(e){return m5({appearance:e,opaqueWindowsEnabled:this.isOpaqueWindowsEnabled(),platform:process.platform})||!uP()&&!f5(e)}",
      "...process.platform===`win32`?{autoHideMenuBar:!0}:{},",
      "process.platform===`win32`&&D.removeMenu(),",
      ")}),D.once(`ready-to-show`,()=>{",
      "",
    ].join("\n"),
    "utf8",
  );

  const patchResult = spawnSync(
    process.execPath,
    [path.join(repoDir, "scripts", "patch-linux-window-ui.js"), tempDir],
    { encoding: "utf8" },
  );

  assert.strictEqual(
    patchResult.status,
    0,
    `patcher failed:\nstdout: ${patchResult.stdout}\nstderr: ${patchResult.stderr}`,
  );

  const bundleSource = fs.readFileSync(bundlePath, "utf8");
  assert.match(
    bundleSource,
    /process\.platform===`linux`&&!f5\(e\)\|\|m5\(/,
    "Linux primary windows should use an opaque background surface",
  );

  const unsupportedDirectory = path.join(tempDir, "unsupported");
  const unsupportedAssetsDirectory = path.join(unsupportedDirectory, "webview", "assets");
  const unsupportedBuildDirectory = path.join(unsupportedDirectory, ".vite", "build");
  fs.mkdirSync(unsupportedAssetsDirectory, { recursive: true });
  fs.mkdirSync(unsupportedBuildDirectory, { recursive: true });
  fs.writeFileSync(path.join(unsupportedAssetsDirectory, "app-test.png"), "fake png", "utf8");
  fs.writeFileSync(path.join(unsupportedBuildDirectory, "main-test.js"), "unrecognized();\n", "utf8");

  const unsupportedResult = spawnSync(
    process.execPath,
    [path.join(repoDir, "scripts", "patch-linux-window-ui.js"), unsupportedDirectory],
    { encoding: "utf8" },
  );
  assert.notStrictEqual(
    unsupportedResult.status,
    0,
    "patcher should fail when upstream contains no recognized Linux patch points",
  );

  console.log("linux-window-ui-patch tests passed");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
