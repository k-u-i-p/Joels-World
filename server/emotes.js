/**
 * The valid emote names, server-side.
 *
 * These used to be scraped out of the web client's `emotes.js` with a regular expression by
 * both `static.js` (for `/api/config`) and `AIAgentManager.js` (for the AI agents' prompt),
 * which made the client a build dependency of the server. Moving them here is what let the
 * native rewrite delete it — see `native/PLAN.md` §8.
 *
 * The poses themselves live in `native/Engine/Entity/Emotes.swift`; the server only ever
 * needed the names. **Keep this list in step with that table** — adding an emote means adding
 * it in both places, and the server rejects any name that is not here.
 */
export const VALID_EMOTES = [
  'bounce',
  'cry',
  'dance',
  'dead',
  'eat',
  'fart',
  'gritty',
  'jump',
  'laser',
  'laugh',
  'love',
  'lunch',
  'rugby',
  'sit',
  'sleep',
  'swim',
  'tennis',
  'wave',
  'wet',
  'write',
];
