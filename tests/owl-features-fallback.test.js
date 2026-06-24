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

  const bootstrapPath = path.join(buildDir, "bootstrap.js");
  fs.writeFileSync(
    bootstrapPath,
    "require('./workspace-root-drop-handler.js');\n",
    "utf8",
  );

  const featureProbePath = path.join(buildDir, "feature-probe.txt");
  fs.writeFileSync(
    path.join(buildDir, "workspace-root-drop-handler.js"),
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

  const runtimeResult = spawnSync(process.execPath, [bootstrapPath], {
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
