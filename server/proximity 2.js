/**
 * Who is standing near whom.
 *
 * All that is left of the server's copy of the physics. Collision, clip masks, movement and
 * interpolation ran here when the browser client shared this file; the native apps simulate
 * their own movement and the server only relays the result, so the one question it still asks
 * of the world is this one: which NPCs is a player close enough to have woken up.
 *
 * `native/Engine/World/Physics.swift` is the live collision engine. It is not a port of
 * anything here any more — nothing here to port.
 */

/** Default interaction radius for a character that does not declare one. */
const DEFAULT_INTERACTION_RADIUS = 150;

/**
 * The characters within their own interaction radius of a point.
 *
 * @param {Array<Object>} charactersList - Characters to test, each with `x`, `y` and an
 *   optional `interaction_radius`.
 * @param {number} x - Probe X, normally a player's position.
 * @param {number} y - Probe Y.
 * @param {number|null} [ignoreId=null] - A character id to skip, so a player does not find
 *   themselves.
 * @returns {Array<Object>} The matching characters, in list order.
 */
export function findCharactersNear(charactersList, x, y, ignoreId = null) {
  const found = [];
  if (!charactersList) return found;

  for (let i = 0, len = charactersList.length; i < len; i++) {
    const c = charactersList[i];
    if (ignoreId && c.id === ignoreId) continue;

    const dx = x - c.x;
    const dy = y - c.y;
    const distSq = dx * dx + dy * dy;

    const radius = c.interaction_radius || DEFAULT_INTERACTION_RADIUS;

    if (distSq <= radius * radius) found.push(c);
  }

  return found;
}
