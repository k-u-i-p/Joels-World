import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..', '..');

/**
 * Where each stage of the pipeline reads and writes.
 *
 * The two trees are the repository's, not this tool's: `assets/` is the art working tree the
 * slicer reads from and writes chunks back into, and `data/` is the authored world the apps
 * and the server share. `server/paths.js` resolves the same `data/` for the same reason.
 */
export const ASSETS_DIR = path.resolve(ROOT, 'assets');
export const MINIMAPS_DIR = path.resolve(ASSETS_DIR, 'minimaps');
export const MAPS_JSON = path.resolve(ROOT, 'data', 'maps.json');

/**
 * An asset reference from `maps.json` — `/junior_school/base.png` — as a path relative to
 * `assets/`.
 *
 * The references are written with a leading slash because they were URLs when the browser
 * client fetched them; on disk that slash would make `path.join` return an absolute path
 * outside the tree, so it is stripped. Every stage that derives an output name from an input
 * (`…_overlay.png`, `chunks/`) works from this relative form.
 *
 * @param {string} reference - An asset path as `maps.json` writes it.
 * @returns {string} The same path, relative to `assets/`.
 */
export function assetRelative(reference) {
  return reference.startsWith('/') ? reference.substring(1) : reference;
}

/**
 * Resolves an asset reference from `maps.json` to an absolute path under `assets/`.
 *
 * @param {...string} parts - An asset reference, optionally followed by path segments to
 *   append.
 * @returns {string} Absolute path under `assets/`.
 */
export function assetPath(...parts) {
  const [reference, ...rest] = parts;
  return path.join(ASSETS_DIR, assetRelative(reference), ...rest);
}

/**
 * Reads the map definitions, or logs why it could not and returns null.
 *
 * Every stage begins with this and skips itself when it fails, rather than throwing: a
 * missing or malformed `maps.json` should report once per stage and leave the already-built
 * assets alone, not abort the run half way through.
 *
 * @param {string} tag - The stage's log prefix, e.g. `[Chunker]`.
 * @returns {Array<Object>|null} The parsed maps, or null.
 */
export function readMaps(tag) {
  try {
    return JSON.parse(fs.readFileSync(MAPS_JSON, 'utf8'));
  } catch (err) {
    console.error(`${tag} Error reading maps.json:`, err);
    return null;
  }
}

/**
 * Writes the map definitions back, for the one stage that edits them: the slicer records the
 * chunk grid it produced against each layer.
 *
 * @param {Array<Object>} maps - The maps to write.
 */
export function writeMaps(maps) {
  fs.writeFileSync(MAPS_JSON, JSON.stringify(maps, null, 2));
}
