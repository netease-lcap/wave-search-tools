"use strict";

const fs = require("fs");
const path = require("path");

/**
 * Platform package per `${process.platform}-${process.arch}`.
 *
 * A platform is listed here only when we actually build binaries for it. The
 * wave side treats a missing entry the same way it treats a failed download:
 * the Bash tool falls back to the system grep/find and nothing else breaks.
 */
const PLATFORM_PACKAGE = {
  "darwin-arm64": "wave-search-tools-darwin-arm64",
  "darwin-x64": "wave-search-tools-darwin-x64",
  "linux-arm64": "wave-search-tools-linux-arm64",
  "linux-x64": "wave-search-tools-linux-x64",
  "win32-x64": "wave-search-tools-win32-x64",
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

/**
 * Whether [name] is installed somewhere *this* module's require would look.
 *
 * Probing an absent package with `require.resolve` is not free: Node remembers
 * the miss for the rest of the process, so a package that lands on disk later
 * never resolves in that process. wave hits exactly that shape — it probes, then
 * downloads, then probes again — and a long-lived daemon that asked once too
 * early stayed broken for its whole lifetime (the same hazard wave's own
 * `utils/packageOnDisk.ts` documents). Checking the candidate directories first
 * keeps the resolver uncontaminated.
 */
function isPackageOnDisk(name) {
  const candidates = require.resolve.paths(name);
  if (!candidates) return true;
  return candidates.some((dir) => fs.existsSync(path.join(dir, name)));
}

function packageDir(name) {
  if (!isPackageOnDisk(name)) return undefined;
  try {
    return path.dirname(require.resolve(`${name}/package.json`));
  } catch {
    return undefined;
  }
}

/**
 * Resolve the binaries for this process's platform.
 *
 * Resolution starts from *this* file, because the platform packages are this
 * package's own optionalDependencies: pnpm nests them under
 * `node_modules/.pnpm/wave-search-tools@<v>/node_modules/`, npm / yarn / hoisted
 * installs put them next to the consumer — `require` from here walks up and
 * finds both layouts. Taking a consumer-bound require instead (the 0.2.x API,
 * `resolveSearchTools(require)`) made the answer depend on the caller's layout
 * and failed on every pnpm install, wave's own monorepo included.
 *
 * The old call shape still works: the argument is simply ignored.
 *
 * @returns {{ ugrep?: string, bfs?: string } | null} null when this platform
 *   has no installed package; missing individual tools are simply omitted.
 */
function resolveSearchTools() {
  const name = PLATFORM_PACKAGE[`${process.platform}-${process.arch}`];
  if (!name) return null;

  const dir = packageDir(name);
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
