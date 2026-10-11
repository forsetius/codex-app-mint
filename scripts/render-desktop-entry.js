#!/usr/bin/env node

const fs = require("fs");

const [templatePath, outputPath, executablePath, iconPath] = process.argv.slice(2);

if (!templatePath || !outputPath || !executablePath || !iconPath) {
  console.error(
    "Usage: render-desktop-entry.js <template> <output> <executable-path> <icon-path>",
  );
  process.exit(1);
}

function assertValidDesktopPath(value, label) {
  const containsControlCharacter = Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0);
    return codePoint < 32 || codePoint === 127;
  });
  if (containsControlCharacter) {
    throw new Error(`${label} contains a control character`);
  }
}

function escapeDesktopString(value) {
  return value.replace(/\\/g, "\\\\");
}

function quoteDesktopExecArgument(value) {
  const escapedValue = value
    .replace(/%/g, "%%")
    .replace(/\\/g, "\\".repeat(4))
    .replace(/["$`]/g, (character) => `${"\\".repeat(2)}${character}`);
  return `"${escapedValue}"`;
}

assertValidDesktopPath(executablePath, "Executable path");
assertValidDesktopPath(iconPath, "Icon path");
if (executablePath.includes("=")) {
  throw new Error("Executable path must not contain an equals sign");
}

const replacements = {
  __EXEC__: quoteDesktopExecArgument(executablePath),
  __TRYEXEC__: escapeDesktopString(executablePath),
  __ICON__: escapeDesktopString(iconPath),
};
let output = fs.readFileSync(templatePath, "utf8");

for (const [placeholder, replacement] of Object.entries(replacements)) {
  if (!output.includes(placeholder)) {
    throw new Error(`Desktop template is missing ${placeholder}`);
  }
}
output = output.replace(
  /__EXEC__|__TRYEXEC__|__ICON__/g,
  (placeholder) => replacements[placeholder],
);

fs.writeFileSync(outputPath, output, "utf8");
