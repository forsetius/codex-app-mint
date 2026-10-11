#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[2];

if (!extractedDir) {
  console.error("Usage: patch-owl-features-fallback.js <extracted-app-asar-dir>");
  process.exit(1);
}

const buildDir = path.join(extractedDir, ".vite", "build");
const packageJsonPath = path.join(extractedDir, "package.json");
const marker = "codexLinuxOwlFeaturesFallback";

function resolveBootstrapPath() {
  if (fs.existsSync(packageJsonPath)) {
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
    if (typeof packageJson.main === "string") {
      const mainPath = path.resolve(extractedDir, packageJson.main);
      const extractedDirectoryPrefix = `${path.resolve(extractedDir)}${path.sep}`;
      if (mainPath.startsWith(extractedDirectoryPrefix) && fs.existsSync(mainPath)) {
        return mainPath;
      }
    }
  }

  return path.join(buildDir, "bootstrap.js");
}

const bootstrapPath = resolveBootstrapPath();

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

function patchBootstrapFailureLogging(javaScriptFiles) {
  const bootstrapFailureMessage = "Desktop bootstrap failed to start the main app";
  const loggingMarker = "[codex-linux] Desktop bootstrap failed";

  for (const filePath of javaScriptFiles) {
    let source = fs.readFileSync(filePath, "utf8");
    const failureMessageIndex = source.indexOf(bootstrapFailureMessage);
    if (failureMessageIndex === -1 || source.includes(loggingMarker)) {
      continue;
    }

    const precedingSource = source.slice(0, failureMessageIndex);
    const catchMatches = [
      ...precedingSource.matchAll(/catch\(([A-Za-z_$][\w$]*)\)\{/g),
    ];
    const catchMatch = catchMatches.at(-1);
    if (!catchMatch || catchMatch.index == null) {
      console.warn(`WARN: Could not find the desktop bootstrap catch block in ${filePath}`);
      return;
    }

    const insertionIndex = catchMatch.index + catchMatch[0].length;
    const errorVariable = catchMatch[1];
    const loggingStatement =
      `process.platform===\`linux\`&&console.error(\`${loggingMarker}\`,${errorVariable});`;
    source = `${source.slice(0, insertionIndex)}${loggingStatement}${source.slice(insertionIndex)}`;
    fs.writeFileSync(filePath, source, "utf8");
    return;
  }
}

function patchOptionalDownloadHistory(javaScriptFiles) {
  for (const filePath of javaScriptFiles) {
    let source = fs.readFileSync(filePath, "utf8");
    const originalSource = source;

    source = source.replaceAll(
      ".getDownloadHistory().catch(()=>null)",
      ".getDownloadHistory?.().catch(()=>null)??Promise.resolve(null)",
    );
    source = source.replace(
      /async readNativeHistory\(\)\{return this\.browserSession==null\?null:\(await this\.browserSession\.getDownloadHistory\(\)\)\.filter\(([A-Za-z_$][\w$]*)\)\}/g,
      (_match, filterFunctionName) =>
        `async readNativeHistory(){return this.browserSession==null||typeof this.browserSession.getDownloadHistory!==\`function\`?null:(await this.browserSession.getDownloadHistory()).filter(${filterFunctionName})}`,
    );
    source = source.replace(
      /this\.browserSession==null\?null:\(await this\.browserSession\.searchDownloadHistory\(([A-Za-z_$][\w$]*)\)\)\.filter\(([A-Za-z_$][\w$]*)\)/g,
      (_match, searchArgumentsName, filterFunctionName) =>
        `this.browserSession==null||typeof this.browserSession.searchDownloadHistory!==\`function\`?null:(await this.browserSession.searchDownloadHistory(${searchArgumentsName})).filter(${filterFunctionName})`,
    );

    if (source !== originalSource) {
      fs.writeFileSync(filePath, source, "utf8");
    }
  }
}

if (!fs.existsSync(buildDir) || !fs.existsSync(bootstrapPath)) {
  throw new Error("Required bootstrap file for OWL patching was not found");
}

const javaScriptFiles = readJavaScriptFiles(buildDir);
const usesOwlFeatures = javaScriptFiles.some((filePath) =>
  fs.readFileSync(filePath, "utf8").includes("electron_common_owl_features"),
);
const requiresOwlAppShell = javaScriptFiles.some((filePath) =>
  fs
    .readFileSync(filePath, "utf8")
    .includes("Codex requires the Owl app shell; stock Electron is no longer supported."),
);

patchBootstrapFailureLogging(javaScriptFiles);

if (!usesOwlFeatures && !requiresOwlAppShell) {
  console.log("No OWL compatibility requirements found. Skipping.");
  process.exit(0);
}

patchOptionalDownloadHistory(javaScriptFiles);

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

  if (process.platform === "linux" && process.versions.electron != null) {
    const electron = require("electron");
    const defineMissingMethod = (target, methodName, implementation) => {
      if (target != null && typeof target[methodName] !== "function") {
        target[methodName] = implementation;
      }
    };
    const noOperation = () => {};
    const emptyAsyncResult = async () => [];
    const falseAsyncResult = async () => false;
    const unsupportedFeature = () => false;

    for (const methodName of [
      "beginNativeMenuTracking",
      "endNativeMenuTracking",
      "setDebugChromePagesEnabled",
      "setRuntimeFeatures",
      "showTaskManager",
    ]) {
      defineMissingMethod(electron.app, methodName, noOperation);
    }

    defineMissingMethod(electron.app, "isRuntimeFeatureEnabled", unsupportedFeature);
    defineMissingMethod(electron.BrowserWindow, "isInputShapeSupported", unsupportedFeature);
    defineMissingMethod(electron.BrowserWindow, "isSystemBackdropSupported", unsupportedFeature);

    const enhanceSession = (session) => {
      if (session == null) {
        return session;
      }

      defineMissingMethod(session, "setPreferredLanguages", noOperation);
      defineMissingMethod(session, "searchHistory", emptyAsyncResult);
      defineMissingMethod(session, "removeBrowsingHistoryEntries", falseAsyncResult);
      defineMissingMethod(session, "getBrowsingDataSettings", async () => ({
        dataRemovalPermitted: {
          downloads: false,
          history: false,
        },
      }));
      if (session.faviconService == null) {
        session.faviconService = {
          getFaviconForIconURL: async () => null,
          getFaviconForPageURL: async () => null,
        };
      }
      return session;
    };
    if (typeof electron.session?.fromPartition === "function") {
      const originalFromPartition = electron.session.fromPartition.bind(electron.session);
      electron.session.fromPartition = (...args) => enhanceSession(originalFromPartition(...args));
    }
    electron.app.whenReady().then(() => enhanceSession(electron.session?.defaultSession));
  }

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
