"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PACKAGE_DIR = path.join(__dirname, "..");
const INDEX = path.join(PACKAGE_DIR, "index.js");

/** `${platform}-${arch}` key this process resolves, e.g. `linux-x64`. */
const key = `${process.platform}-${process.arch}`;
const platformPackage = `wave-search-tools-${key}`;
const binarySuffix = process.platform === "win32" ? ".exe" : "";

/**
 * Build a throwaway install and return a require() of the copied `index.js`.
 *
 * [layout] picks where the platform package goes:
 * - `pnpm` nests it under the wrapper's own node_modules (what pnpm produces:
 *   `node_modules/.pnpm/<wrapper>@<v>/node_modules/<wrapper>/`);
 * - `flat` puts both packages side by side in one node_modules (npm, yarn,
 *   pnpm with `node-linker=hoisted`).
 */
function fakeInstall(t, layout) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "wave-search-tools-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const wrapperDir =
    layout === "pnpm"
      ? path.join(
          root,
          "node_modules",
          ".pnpm",
          "wave-search-tools@0.3.0",
          "node_modules",
          "wave-search-tools",
        )
      : path.join(root, "node_modules", "wave-search-tools");
  fs.mkdirSync(wrapperDir, { recursive: true });
  fs.copyFileSync(INDEX, path.join(wrapperDir, "index.js"));

  const platformDir =
    layout === "pnpm"
      ? path.join(path.dirname(wrapperDir), platformPackage)
      : path.join(root, "node_modules", platformPackage);

  return {
    root,
    wrapperIndex: path.join(wrapperDir, "index.js"),
    /** Create the platform package (and a placeholder binary) on disk. */
    addPlatformPackage() {
      fs.mkdirSync(path.join(platformDir, "bin"), { recursive: true });
      fs.writeFileSync(
        path.join(platformDir, "package.json"),
        JSON.stringify({ name: platformPackage, version: "0.2.0" }),
      );
      for (const tool of ["ugrep", "bfs"]) {
        fs.writeFileSync(path.join(platformDir, "bin", tool + binarySuffix), "");
      }
      return platformDir;
    },
  };
}

/** A fresh copy of the module, so each case starts without Node's cache. */
function load(wrapperIndex) {
  delete require.cache[wrapperIndex];
  return require(wrapperIndex);
}

test(`resolves the platform package pnpm nests under the wrapper`, (t) => {
  const install = fakeInstall(t, "pnpm");
  const binDir = path.join(install.addPlatformPackage(), "bin");

  const tools = load(install.wrapperIndex).resolveSearchTools();

  assert.ok(tools, "expected a resolution, got null");
  assert.equal(tools.ugrep, path.join(binDir, "ugrep" + binarySuffix));
  if (process.platform !== "win32") {
    assert.equal(tools.bfs, path.join(binDir, "bfs" + binarySuffix));
  } else {
    // Windows packs ugrep only; git bash already provides GNU find.
    assert.deepEqual(Object.keys(tools), ["ugrep"]);
  }
});

test(`resolves the platform package in a flat install`, (t) => {
  const install = fakeInstall(t, "flat");
  const binDir = path.join(install.addPlatformPackage(), "bin");

  const tools = load(install.wrapperIndex).resolveSearchTools();

  assert.ok(tools, "expected a resolution, got null");
  assert.equal(tools.ugrep, path.join(binDir, "ugrep" + binarySuffix));
});

test(`ignores the argument of the 0.2.x call shape`, (t) => {
  const install = fakeInstall(t, "pnpm");
  install.addPlatformPackage();

  // `resolveSearchTools(require)` was the documented API; callers in the wild
  // still pass it. The consumer-bound require is what broke pnpm resolution, so
  // the argument must not take part in it any more.
  const tools = load(install.wrapperIndex).resolveSearchTools(
    // A require that would actively fail if it were still consulted.
    () => {
      throw new Error("consumer require must not be used");
    },
  );

  assert.ok(tools, "expected a resolution, got null");
  assert.ok(tools.ugrep.endsWith("ugrep" + binarySuffix));
});

test(`returns null when the platform package is missing, then resolves once it lands`, (t) => {
  // The install-then-reprobe shape wave's runtime-dependency installer has: a
  // miss must not poison this process (that is why existence is checked on disk
  // before `require.resolve` runs).
  const install = fakeInstall(t, "pnpm");
  const mod = load(install.wrapperIndex);

  assert.equal(mod.resolveSearchTools(), null);

  const binDir = path.join(install.addPlatformPackage(), "bin");
  const tools = mod.resolveSearchTools();

  assert.ok(tools, "expected a resolution after the package landed");
  assert.equal(tools.ugrep, path.join(binDir, "ugrep" + binarySuffix));
});

test(`returns null for a platform that has no build`, (t) => {
  const install = fakeInstall(t, "pnpm");
  install.addPlatformPackage();

  // Keyed off `process.platform`, so the only way to reach the unsupported
  // branch on a supported machine is to pretend to be something else.
  const original = Object.getOwnPropertyDescriptor(process, "platform");
  Object.defineProperty(process, "platform", {
    value: "sunos",
    configurable: true,
  });
  try {
    assert.equal(load(install.wrapperIndex).resolveSearchTools(), null);
  } finally {
    Object.defineProperty(process, "platform", original);
  }
});
