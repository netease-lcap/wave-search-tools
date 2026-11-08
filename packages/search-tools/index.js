"use strict";

const path = require("path");

/**
 * Platform package per `${process.platform}-${process.arch}`.
 *
 * A platform is listed here only when we actually build binaries for it. The
 * wave side treats a missing entry the same way it treats a failed download:
 * the Bash tool falls back to the system grep/find and nothing else breaks.
 */
const PLATFORM_PACKAGE = {
  "darwin-arm64": "@wave/search-tools-darwin-arm64",
  "darwin-x64": "@wave/search-tools-darwin-x64",
  "linux-arm64": "@wave/search-tools-linux-arm64",
  "linux-x64": "@wave/search-tools-linux-x64",
  "win32-x64": "@wave/search-tools-win32-x64",
};

/**
 * Windows ships ugrep only: the required git bash already provides a complete
 * GNU find, so bfs would duplicate it, while GNU grep lacks `--ignore-files`
 * (which is exactly what the find/grep injection needs).
 */
const TOOLS_BY_PLATFORM = {
  win32: ["ugrep"],
};

function toolsFor(platform) {
  return TOOLS_BY_PLATFORM[platform] ?? ["ugrep", "bfs"];
}

function packageDir(requireFn, name) {
  try {
    return path.dirname(requireFn.resolve(`${name}/package.json`));
  } catch {
    return undefined;
  }
}

/**
 * Resolve the binaries for this process's platform.
 *
 * @param {NodeRequire["resolve"] extends Function ? { resolve(id: string): string } : never} requireFn
 *   A require bound to the *consumer's* location (wave passes
 *   `createRequire(import.meta.url)`), not this package's — the platform
 *   packages are siblings in the consumer's node_modules, not ours.
 * @returns {{ ugrep?: string, bfs?: string } | null} null when this platform
 *   has no installed package; missing individual tools are simply omitted.
 */
function resolveSearchTools(requireFn) {
  const name = PLATFORM_PACKAGE[`${process.platform}-${process.arch}`];
  if (!name) return null;

  const dir = packageDir(requireFn, name);
  if (!dir) return null;

  const suffix = process.platform === "win32" ? ".exe" : "";
  const result = {};
  for (const tool of toolsFor(process.platform)) {
    // Existence is intentionally not checked here: require.resolve on the
    // package.json already proves the package is installed, and a missing
    // binary inside it means a corrupt install worth surfacing loudly.
    result[tool] = path.join(dir, "bin", tool + suffix);
  }
  return result;
}

module.exports = { resolveSearchTools, PLATFORM_PACKAGE };
