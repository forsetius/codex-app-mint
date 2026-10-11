#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[2];

if (!extractedDir) {
  console.error("Usage: patch-native-module-loaders.js <extracted-app-asar-dir>");
  process.exit(1);
}

const betterSqlite3File = path.join(
  extractedDir,
  "node_modules",
  "better-sqlite3",
  "lib",
  "database.js",
);

const nodePtyUtilsFile = path.join(
  extractedDir,
  "node_modules",
  "node-pty",
  "lib",
  "utils.js",
);

function replaceRequired(source, searchValue, replaceValue, filePath, label) {
  if (!source.includes(searchValue)) {
    throw new Error(`Could not find ${label} in ${filePath}`);
  }

  return source.replace(searchValue, replaceValue);
}

function patchBetterSqlite3(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`better-sqlite3 file not found: ${filePath}`);
  }

  let source = fs.readFileSync(filePath, "utf8");
  if (source.includes("resolveUnpackedNativePath")) {
    return null;
  }

  source = replaceRequired(
    source,
    "let DEFAULT_ADDON;\n",
    `let DEFAULT_ADDON;\n` +
      `const resolveUnpackedNativePath = (inputPath) => inputPath.includes(\`${path.sep}app.asar${path.sep}\`)\n` +
      `\t? inputPath.replace(\`${path.sep}app.asar${path.sep}\`, \`${path.sep}app.asar.unpacked${path.sep}\`)\n` +
      `\t: inputPath;\n`,
    filePath,
    "better-sqlite3 helper insertion point",
  );

  source = replaceRequired(
    source,
    "addon = DEFAULT_ADDON || (DEFAULT_ADDON = require('bindings')('better_sqlite3.node'));",
    `const requireFunc = typeof __non_webpack_require__ === 'function' ? __non_webpack_require__ : require;\n` +
      `\t\tconst nativeModulePath = resolveUnpackedNativePath(path.join(__dirname, '..', 'build', 'Release', 'better_sqlite3.node'));\n` +
      `\t\ttry {\n` +
      `\t\t\taddon = DEFAULT_ADDON || (DEFAULT_ADDON = requireFunc(nativeModulePath));\n` +
      `\t\t} catch {\n` +
      `\t\t\taddon = DEFAULT_ADDON || (DEFAULT_ADDON = require('bindings')('better_sqlite3.node'));\n` +
      `\t\t}`,
    filePath,
    "better-sqlite3 native binding loader",
  );

  return source;
}

function patchNodePty(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`node-pty file not found: ${filePath}`);
  }

  let source = fs.readFileSync(filePath, "utf8");
  if (source.includes("resolveUnpackedNativePath")) {
    return null;
  }

  source = replaceRequired(
    source,
    "Object.defineProperty(exports, \"__esModule\", { value: true });\nexports.loadNativeModule = exports.assign = void 0;\n",
    "Object.defineProperty(exports, \"__esModule\", { value: true });\nexports.loadNativeModule = exports.assign = void 0;\nvar path = require(\"path\");\nvar resolveUnpackedNativePath = function (inputPath) {\n    return inputPath.includes(\"/app.asar/\") ? inputPath.replace(\"/app.asar/\", \"/app.asar.unpacked/\") : inputPath;\n};\n",
    filePath,
    "node-pty helper insertion point",
  );

  source = replaceRequired(
    source,
    "                return { dir: dir, module: require(dir + \"/\" + name + \".node\") };",
    "                var nativeModulePath = resolveUnpackedNativePath(path.join(__dirname, dir, name + \".node\"));\n                return { dir: dir, module: require(nativeModulePath) };",
    filePath,
    "node-pty native loader",
  );

  return source;
}

const patchedBetterSqlite3Source = patchBetterSqlite3(betterSqlite3File);
const patchedNodePtySource = patchNodePty(nodePtyUtilsFile);

if (patchedBetterSqlite3Source != null) {
  fs.writeFileSync(betterSqlite3File, patchedBetterSqlite3Source, "utf8");
}
if (patchedNodePtySource != null) {
  fs.writeFileSync(nodePtyUtilsFile, patchedNodePtySource, "utf8");
}

console.log("Patched native module loaders:", {
  betterSqlite3File,
  nodePtyUtilsFile,
});
