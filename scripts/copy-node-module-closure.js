#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const sourceNodeModulesDirectory = process.argv[2];
const targetNodeModulesDirectory = process.argv[3];
const rootPackageName = process.argv[4];

if (!sourceNodeModulesDirectory || !targetNodeModulesDirectory || !rootPackageName) {
  console.error(
    "Usage: copy-node-module-closure.js <source-node-modules> <target-node-modules> <package-name>",
  );
  process.exit(1);
}

const normalizedSourceDirectory = path.resolve(sourceNodeModulesDirectory);
const normalizedTargetDirectory = path.resolve(targetNodeModulesDirectory);
const copiedPackageDirectories = new Set();

if (normalizedTargetDirectory === path.parse(normalizedTargetDirectory).root) {
  throw new Error(`Target node_modules directory must not be a filesystem root: ${normalizedTargetDirectory}`);
}
if (
  normalizedSourceDirectory === normalizedTargetDirectory ||
  normalizedSourceDirectory.startsWith(`${normalizedTargetDirectory}${path.sep}`) ||
  normalizedTargetDirectory.startsWith(`${normalizedSourceDirectory}${path.sep}`)
) {
  throw new Error("Source and target node_modules directories must not overlap");
}

function packagePathSegments(packageName) {
  const segments = packageName.split("/");
  if (
    segments.length > 2 ||
    segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")
  ) {
    throw new Error(`Invalid package name: ${packageName}`);
  }

  return segments;
}

function findInstalledPackageDirectory(packageName, requestingPackageDirectory) {
  const packageSegments = packagePathSegments(packageName);
  let searchDirectory = requestingPackageDirectory;

  while (
    searchDirectory === normalizedSourceDirectory ||
    searchDirectory.startsWith(`${normalizedSourceDirectory}${path.sep}`)
  ) {
    const candidate =
      searchDirectory === normalizedSourceDirectory
        ? path.join(searchDirectory, ...packageSegments)
        : path.join(searchDirectory, "node_modules", ...packageSegments);
    if (fs.existsSync(path.join(candidate, "package.json"))) {
      return candidate;
    }
    if (searchDirectory === normalizedSourceDirectory) {
      break;
    }
    searchDirectory = path.dirname(searchDirectory);
  }

  return null;
}

function copyPackage(packageName, requestingPackageDirectory, optional = false) {
  const sourcePackageDirectory = findInstalledPackageDirectory(
    packageName,
    requestingPackageDirectory,
  );
  if (!sourcePackageDirectory) {
    if (optional) {
      return;
    }
    throw new Error(
      `Required dependency ${packageName} was not found for ${requestingPackageDirectory}`,
    );
  }
  if (copiedPackageDirectories.has(sourcePackageDirectory)) {
    return;
  }

  copiedPackageDirectories.add(sourcePackageDirectory);
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(sourcePackageDirectory, "package.json"), "utf8"),
  );
  for (const dependencyName of Object.keys(packageJson.dependencies ?? {})) {
    copyPackage(dependencyName, sourcePackageDirectory);
  }
  for (const dependencyName of Object.keys(packageJson.optionalDependencies ?? {})) {
    copyPackage(dependencyName, sourcePackageDirectory, true);
  }

  const relativePackageDirectory = path.relative(
    normalizedSourceDirectory,
    sourcePackageDirectory,
  );
  if (
    relativePackageDirectory === "" ||
    relativePackageDirectory === ".." ||
    relativePackageDirectory.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relativePackageDirectory)
  ) {
    throw new Error(`Package path escapes source node_modules: ${sourcePackageDirectory}`);
  }

  const targetPackageDirectory = path.join(normalizedTargetDirectory, relativePackageDirectory);
  fs.rmSync(targetPackageDirectory, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(targetPackageDirectory), { recursive: true });
  fs.cpSync(sourcePackageDirectory, targetPackageDirectory, { recursive: true });
}

copyPackage(rootPackageName, normalizedSourceDirectory);
