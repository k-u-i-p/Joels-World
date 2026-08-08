import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * The authored world — `maps.json`, and every map's `objects.json` and `npc.json`.
 *
 * It sits at the repository root rather than under `server/` because it is no longer the
 * server's alone: the apps bundle it (`tools/assets/stage.sh`), the macOS editor writes it,
 * and the server reads it and watches it for changes. The AI agents' prompt files and logs
 * live in the same tree but stay server-side — `stage.sh` does not copy them.
 */
export const DATA_DIR = path.resolve(__dirname, '..', 'data');

export function dataPath(...parts) {
  return path.resolve(DATA_DIR, ...parts);
}
