#!/usr/bin/env node

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const repoDirectory = path.resolve(__dirname, "..");
const temporaryDirectory = fs.mkdtempSync(
  path.join(os.tmpdir(), "codex-native-loader-test-"),
);
const patcherPath = path.join(repoDirectory, "scripts", "patch-native-module-loaders.js");

function createFixture(rootDirectory, completeBetterSqlite3Loader, completeNodePtyLoader = true) {
  const betterSqlite3Path = path.join(
    rootDirectory,
    "node_modules",
    "better-sqlite3",
    "lib",
    "database.js",
  );
  const nodePtyPath = path.join(
    rootDirectory,
    "node_modules",
    "node-pty",
    "lib",
    "utils.js",
  );
  fs.mkdirSync(path.dirname(betterSqlite3Path), { recursive: true });
  fs.mkdirSync(path.dirname(nodePtyPath), { recursive: true });
  fs.writeFileSync(
    betterSqlite3Path,
    [
      "const path = require('path');",
      "let DEFAULT_ADDON;",
      completeBetterSqlite3Loader
        ? "addon = DEFAULT_ADDON || (DEFAULT_ADDON = require('bindings')('better_sqlite3.node'));"
        : "addon = loadUnexpectedBinding();",
      "",
    ].join("\n"),
    "utf8",
  );
  fs.writeFileSync(
    nodePtyPath,
    [
      'Object.defineProperty(exports, "__esModule", { value: true });',
      "exports.loadNativeModule = exports.assign = void 0;",
      completeNodePtyLoader
        ? "                return { dir: dir, module: require(dir + \"/\" + name + \".node\") };"
        : "                return loadUnexpectedPtyBinding();",
      "",
    ].join("\n"),
    "utf8",
  );

  return { betterSqlite3Path, nodePtyPath };
}

try {
  const validRoot = path.join(temporaryDirectory, "valid");
  const validFixture = createFixture(validRoot, true);
  const validResult = spawnSync(process.execPath, [patcherPath, validRoot], {
    encoding: "utf8",
  });
  assert.strictEqual(
    validResult.status,
    0,
    `valid patch failed:\nstdout: ${validResult.stdout}\nstderr: ${validResult.stderr}`,
  );

  const invalidNodePtyRoot = path.join(temporaryDirectory, "invalid-node-pty");
  const invalidNodePtyFixture = createFixture(invalidNodePtyRoot, true, false);
  const originalBetterSqlite3Source = fs.readFileSync(
    invalidNodePtyFixture.betterSqlite3Path,
    "utf8",
  );
  const invalidNodePtyResult = spawnSync(
    process.execPath,
    [patcherPath, invalidNodePtyRoot],
    { encoding: "utf8" },
  );
  assert.notStrictEqual(
    invalidNodePtyResult.status,
    0,
    "incomplete node-pty patch should fail",
  );
  assert.strictEqual(
    fs.readFileSync(invalidNodePtyFixture.betterSqlite3Path, "utf8"),
    originalBetterSqlite3Source,
    "failure in node-pty must not leave better-sqlite3 partially patched",
  );
  assert.match(fs.readFileSync(validFixture.betterSqlite3Path, "utf8"), /resolveUnpackedNativePath/);
  assert.match(fs.readFileSync(validFixture.nodePtyPath, "utf8"), /resolveUnpackedNativePath/);

  const invalidRoot = path.join(temporaryDirectory, "invalid");
  const invalidFixture = createFixture(invalidRoot, false);
  const originalSource = fs.readFileSync(invalidFixture.betterSqlite3Path, "utf8");
  const invalidResult = spawnSync(process.execPath, [patcherPath, invalidRoot], {
    encoding: "utf8",
  });
  assert.notStrictEqual(invalidResult.status, 0, "incomplete native loader patch should fail");
  assert.strictEqual(
    fs.readFileSync(invalidFixture.betterSqlite3Path, "utf8"),
    originalSource,
    "failed patch must not leave a partially modified file",
  );

  console.log("native-module-loaders tests passed");
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
