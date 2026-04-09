#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[2];

if (!extractedDir) {
  console.error("Usage: patch-linux-window-ui.js <extracted-app-asar-dir>");
  process.exit(1);
}

const assetsDir = path.join(extractedDir, "webview", "assets");
const buildDir = path.join(extractedDir, ".vite", "build");

if (!fs.existsSync(assetsDir) || !fs.existsSync(buildDir)) {
  console.warn("WARN: Required directories for UI patching were not found. Skipping.");
  process.exit(0);
}

const iconAsset = fs
  .readdirSync(assetsDir)
  .find((name) => /^app-.*\.png$/.test(name));

const mainBundle = fs
  .readdirSync(buildDir)
  .find((name) => /^main(?:-[^.]+)?\.js$/.test(name));

if (!iconAsset || !mainBundle) {
  console.warn("WARN: Could not find the icon asset or the main Vite bundle. Skipping.");
  process.exit(0);
}

const target = path.join(buildDir, mainBundle);
let source = fs.readFileSync(target, "utf8");
const packageJsonPath = path.join(extractedDir, "package.json");
const linuxIconPathExpression = `require(\`node:path\`).join(process.resourcesPath,\`..\`,\`content\`,\`webview\`,\`assets\`,\`${iconAsset}\`)`;

const windowOptionsNeedle = "...process.platform===`win32`?{autoHideMenuBar:!0}:{},";
const iconPathNeedle = `icon:${linuxIconPathExpression}`;
const windowOptionsReplacement = `...process.platform===\`win32\`||process.platform===\`linux\`?{autoHideMenuBar:!0,...process.platform===\`linux\`?{${iconPathNeedle}}:{}}:{},`;

if (source.includes(windowOptionsNeedle)) {
  source = source.replace(windowOptionsNeedle, windowOptionsReplacement);
}

const menuNeedle = "process.platform===`win32`&&D.removeMenu(),";
const menuPatch = "process.platform===`linux`&&D.setMenuBarVisibility(!1),";
if (source.includes(menuNeedle) && !source.includes(menuPatch)) {
  source = source.replace(menuNeedle, `${menuPatch}${menuNeedle}`);
}

const setIconNeedle = ")}),D.once(`ready-to-show`,()=>{";
const setIconPatch = `)}),process.platform===\`linux\`&&D.setIcon(${linuxIconPathExpression}),D.once(\`ready-to-show\`,()=>{`;
if (source.includes(setIconNeedle) && !source.includes("&&D.setIcon(")) {
  source = source.replace(setIconNeedle, setIconPatch);
}

const colorConstRegex = /([A-Za-z_$][\w$]*)=`#00000000`,([A-Za-z_$][\w$]*)=`#000000`,([A-Za-z_$][\w$]*)=`#f9f9f9`/;
const colorMatch = source.match(colorConstRegex);
if (colorMatch) {
  const [, transparentVar, darkVar, lightVar] = colorMatch;
  const functionMatch = source.match(/prefersDarkColors:([A-Za-z_$][\w$]*)\}\)\{return\s*([A-Za-z_$][\w$]*)===`win32`/);
  if (functionMatch) {
    const prefersDarkColorsParam = functionMatch[1];
    const backgroundNeedle = `backgroundMaterial:\`mica\`}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;
    const backgroundReplacement = `backgroundMaterial:\`mica\`}:process.platform===\`linux\`?{backgroundColor:${prefersDarkColorsParam}?${darkVar}:${lightVar},backgroundMaterial:null}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;
    if (source.includes(backgroundNeedle)) {
      source = source.replace(backgroundNeedle, backgroundReplacement);
    }
  }
}

fs.writeFileSync(target, source, "utf8");

if (fs.existsSync(packageJsonPath)) {
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  if (packageJson.desktopName !== "codex-desktop.desktop") {
    packageJson.desktopName = "codex-desktop.desktop";
    fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`, "utf8");
  }
}

console.log(`Patched Linux window behavior in ${target}`);
