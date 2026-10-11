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
const copiedPackageDirectories = new Set();

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

  while (searchDirectory.startsWith(`${normalizedSourceDirectory}${path.sep}`)) {
    const nestedCandidate = path.join(searchDirectory, "node_modules", ...packageSegments);
    if (fs.existsSync(path.join(nestedCandidate, "package.json"))) {
      return nestedCandidate;
    }
    searchDirectory = path.dirname(searchDirectory);
  }

  const rootCandidate = path.join(normalizedSourceDirectory, ...packageSegments);
  return fs.existsSync(path.join(rootCandidate, "package.json")) ? rootCandidate : null;
}

function copyPackage(packageName, requestingPackageDirectory) {
  const sourcePackageDirectory = findInstalledPackageDirectory(
    packageName,
    requestingPackageDirectory,
  );
  if (!sourcePackageDirectory || copiedPackageDirectories.has(sourcePackageDirectory)) {
    return;
  }

  copiedPackageDirectories.add(sourcePackageDirectory);
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(sourcePackageDirectory, "package.json"), "utf8"),
  );
  const dependencyNames = Object.keys({
    ...packageJson.dependencies,
    ...packageJson.optionalDependencies,
  });

  for (const dependencyName of dependencyNames) {
    copyPackage(dependencyName, sourcePackageDirectory);
  }

  const targetPackageDirectory = path.join(
    path.resolve(targetNodeModulesDirectory),
    ...packagePathSegments(packageName),
  );
  fs.rmSync(targetPackageDirectory, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(targetPackageDirectory), { recursive: true });
  fs.cpSync(sourcePackageDirectory, targetPackageDirectory, { recursive: true });
}

copyPackage(rootPackageName, normalizedSourceDirectory);
