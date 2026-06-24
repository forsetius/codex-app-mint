#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[2];

if (!extractedDir) {
  console.error("Usage: patch-owl-features-fallback.js <extracted-app-asar-dir>");
  process.exit(1);
}

const buildDir = path.join(extractedDir, ".vite", "build");
const bootstrapPath = path.join(buildDir, "bootstrap.js");
const marker = "codexLinuxOwlFeaturesFallback";

function readJavaScriptFiles(directory) {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...readJavaScriptFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".js")) {
      files.push(entryPath);
    }
  }

  return files;
}

if (!fs.existsSync(buildDir) || !fs.existsSync(bootstrapPath)) {
  console.warn("WARN: Required bootstrap file for OWL patching was not found. Skipping.");
  process.exit(0);
}

const usesOwlFeatures = readJavaScriptFiles(buildDir).some((filePath) =>
  fs.readFileSync(filePath, "utf8").includes("electron_common_owl_features"),
);

if (!usesOwlFeatures) {
  console.log("No OWL feature binding usage found. Skipping.");
  process.exit(0);
}

let source = fs.readFileSync(bootstrapPath, "utf8");

if (source.includes(marker)) {
  console.log(`OWL feature binding fallback already patched in ${bootstrapPath}`);
  process.exit(0);
}

const fallbackSource = `(() => {
  const fallbackMarker = "${marker}";
  if (process[fallbackMarker]) {
    return;
  }

  process[fallbackMarker] = true;
  const originalLinkedBinding = process._linkedBinding;
  const disabledOwlFeatureState = {
    enabledFeatureNames: [],
    disabledFeatureNames: [],
  };
  const disabledOwlFeaturesBase = {
    getState: () => disabledOwlFeatureState,
    isEnabled: () => false,
    isOwlFeatureEnabled: () => false,
    setFeatureNames: () => disabledOwlFeatureState,
  };
  const disabledOwlFeatures = new Proxy(disabledOwlFeaturesBase, {
    get(_target, property) {
      if (property === Symbol.toStringTag) {
        return "DisabledOwlFeatures";
      }

      if (property in disabledOwlFeaturesBase) {
        return disabledOwlFeaturesBase[property];
      }

      return () => false;
    },
  });

  process._linkedBinding = function linkedBindingWithOwlFallback(name) {
    if (name === "electron_common_owl_features") {
      return disabledOwlFeatures;
    }

    return originalLinkedBinding.call(process, name);
  };
})();

`;

fs.writeFileSync(bootstrapPath, `${fallbackSource}${source}`, "utf8");

console.log(`Patched OWL feature binding fallback in ${bootstrapPath}`);
