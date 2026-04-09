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

function replaceOnce(source, searchValue, replaceValue, filePath, label) {
  if (!source.includes(searchValue)) {
    console.warn(`WARN: Could not find ${label} in ${filePath}`);
    return source;
  }

  return source.replace(searchValue, replaceValue);
}

function patchBetterSqlite3(filePath) {
  if (!fs.existsSync(filePath)) {
    console.warn(`WARN: better-sqlite3 file not found: ${filePath}`);
    return;
  }

  let source = fs.readFileSync(filePath, "utf8");
  if (source.includes("resolveUnpackedNativePath")) {
    return;
  }

  source = replaceOnce(
    source,
    "let DEFAULT_ADDON;\n",
    `let DEFAULT_ADDON;\n` +
      `const resolveUnpackedNativePath = (inputPath) => inputPath.includes(\`${path.sep}app.asar${path.sep}\`)\n` +
      `\t? inputPath.replace(\`${path.sep}app.asar${path.sep}\`, \`${path.sep}app.asar.unpacked${path.sep}\`)\n` +
      `\t: inputPath;\n`,
    filePath,
    "better-sqlite3 helper insertion point",
  );

  source = replaceOnce(
    source,
    "addon = DEFAULT_ADDON || (DEFAULT_ADDON = require('bindings')('better_sqlite3.node'));",
    `const requireFunc = typeof __non_webpack_require__ === 'function' ? __non_webpack_require__ : require;\n` +
      `\t\tconst nativeModulePath = resolveUnpackedNativePath(path.join(__dirname, '..', 'build', 'Release', 'better_sqlite3.node'));\n` +
      `\t\ttry {\n` +
      `\t\t\taddon = DEFAULT_ADDON || (DEFAULT_ADDON = requireFunc(nativeModulePath));\n` +
      `\t\t} catch (directRequireError) {\n` +
      `\t\t\taddon = DEFAULT_ADDON || (DEFAULT_ADDON = require('bindings')('better_sqlite3.node'));\n` +
      `\t\t}`,
    filePath,
    "better-sqlite3 native binding loader",
  );

  fs.writeFileSync(filePath, source, "utf8");
}

function patchNodePty(filePath) {
  if (!fs.existsSync(filePath)) {
    console.warn(`WARN: node-pty file not found: ${filePath}`);
    return;
  }

  let source = fs.readFileSync(filePath, "utf8");
  if (source.includes("resolveUnpackedNativePath")) {
    return;
  }

  source = replaceOnce(
    source,
    "Object.defineProperty(exports, \"__esModule\", { value: true });\nexports.loadNativeModule = exports.assign = void 0;\n",
    "Object.defineProperty(exports, \"__esModule\", { value: true });\nexports.loadNativeModule = exports.assign = void 0;\nvar path = require(\"path\");\nvar resolveUnpackedNativePath = function (inputPath) {\n    return inputPath.includes(\"/app.asar/\") ? inputPath.replace(\"/app.asar/\", \"/app.asar.unpacked/\") : inputPath;\n};\n",
    filePath,
    "node-pty helper insertion point",
  );

  source = replaceOnce(
    source,
    "                return { dir: dir, module: require(dir + \"/\" + name + \".node\") };",
    "                var nativeModulePath = resolveUnpackedNativePath(path.join(__dirname, dir, name + \".node\"));\n                return { dir: dir, module: require(nativeModulePath) };",
    filePath,
    "node-pty native loader",
  );

  fs.writeFileSync(filePath, source, "utf8");
}

patchBetterSqlite3(betterSqlite3File);
patchNodePty(nodePtyUtilsFile);

console.log("Patched native module loaders:", {
  betterSqlite3File,
  nodePtyUtilsFile,
});
