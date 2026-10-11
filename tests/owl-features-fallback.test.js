#!/usr/bin/env node

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const repoDir = path.resolve(__dirname, "..");
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-owl-test-"));

try {
  const buildDir = path.join(tempDir, ".vite", "build");
  fs.mkdirSync(buildDir, { recursive: true });

  fs.writeFileSync(
    path.join(tempDir, "package.json"),
    JSON.stringify({ main: ".vite/build/early-bootstrap.js" }),
    "utf8",
  );

  const electronModuleDir = path.join(tempDir, "node_modules", "electron");
  fs.mkdirSync(electronModuleDir, { recursive: true });
  fs.writeFileSync(
    path.join(electronModuleDir, "index.js"),
    "module.exports = { app: { whenReady: () => Promise.resolve() }, BrowserWindow: {}, session: { fromPartition: () => ({}) } };\n",
    "utf8",
  );

  const bootstrapPath = path.join(buildDir, "early-bootstrap.js");
  fs.writeFileSync(
    bootstrapPath,
    "require('./bootstrap-test-hash.js');\n",
    "utf8",
  );

  const featureProbePath = path.join(buildDir, "feature-probe.txt");
  fs.writeFileSync(
    path.join(tempDir, "owl-feature-consumer.js"),
    [
      "const fs = require('fs');",
      `const featureProbePath = ${JSON.stringify(featureProbePath)};`,
      "const owlFeatures = process._linkedBinding('electron_common_owl_features');",
      "if (owlFeatures.isOwlFeatureEnabled('drop-handler')) {",
      "  throw new Error('fallback should disable OWL features');",
      "}",
      "fs.writeFileSync(featureProbePath, 'disabled', 'utf8');",
      "",
    ].join("\n"),
    "utf8",
  );

  fs.writeFileSync(
    path.join(buildDir, "bootstrap-test-hash.js"),
    [
      "const { app, session } = require('electron');",
      "if (process.versions.electron != null && typeof app.showTaskManager !== 'function') {",
      "  throw new Error('Codex requires the Owl app shell; stock Electron is no longer supported.');",
      "}",
      "if (app.isRuntimeFeatureEnabled('test-feature')) {",
      "  throw new Error('stock Electron fallback should disable runtime features');",
      "}",
      "app.setDebugChromePagesEnabled(false);",
      "session.fromPartition('test').setPreferredLanguages(['en']);",
      "require('../../owl-feature-consumer.js');",
      "async function startMainApp(){try{return true}catch(startupError){console.error('Desktop bootstrap failed to start the main app')}}",
      "",
    ].join("\n"),
    "utf8",
  );

  const runtimeArguments = [
    "-e",
    "process.versions.electron = '42.3.0'; require(process.argv[1]);",
    bootstrapPath,
  ];

  const unpatchedRuntimeResult = spawnSync(process.execPath, runtimeArguments, {
    encoding: "utf8",
  });

  assert.notStrictEqual(unpatchedRuntimeResult.status, 0);
  assert.match(
    unpatchedRuntimeResult.stderr,
    /Codex requires the Owl app shell; stock Electron is no longer supported/,
  );

  const patchResult = spawnSync(
    process.execPath,
    [path.join(repoDir, "scripts", "patch-owl-features-fallback.js"), tempDir],
    { encoding: "utf8" },
  );

  assert.strictEqual(
    patchResult.status,
    0,
    `patcher failed:\nstdout: ${patchResult.stdout}\nstderr: ${patchResult.stderr}`,
  );

  const bootstrapSource = fs.readFileSync(bootstrapPath, "utf8");
  assert.match(bootstrapSource, /electron_common_owl_features/);
  assert.match(bootstrapSource, /originalLinkedBinding/);
  assert.match(bootstrapSource, /showTaskManager/);

  const hashedBootstrapSource = fs.readFileSync(
    path.join(buildDir, "bootstrap-test-hash.js"),
    "utf8",
  );
  assert.match(hashedBootstrapSource, /\[codex-linux\] Desktop bootstrap failed/);

  const runtimeResult = spawnSync(process.execPath, runtimeArguments, {
    encoding: "utf8",
  });

  assert.strictEqual(
    runtimeResult.status,
    0,
    `patched bootstrap failed:\nstdout: ${runtimeResult.stdout}\nstderr: ${runtimeResult.stderr}`,
  );
  assert.strictEqual(fs.readFileSync(featureProbePath, "utf8"), "disabled");

  console.log("owl-features-fallback tests passed");
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
