export class PhysicsEngine {
  /**
   * Helper function to detect if a specific coordinate and radius overlaps with a collision object.
   * Applies rotated rectangle math and bounding circle math.
   * @param {Object} obj - The map object to test against.
   * @param {number} x - The target X coordinate.
   * @param {number} y - The target Y coordinate.
   * @param {number} radius - The collision radius around the coords.
   * @param {number} [clipOverlapAllowed=0] - How much overlap is allowed (for clipping calculations).
   * @returns {boolean} True if the entity point overlaps the object bounds.
   */
  checkObjectOverlap(obj, x, y, radius, clipOverlapAllowed = 0) {
    // Broad-phase AABB rejection
    const maxDim = Math.max(obj.width || 0, obj.length || 0) / 2;
    // Account for diagonal/rotation loosely in broad phase by multiplying by sqrt(2) approx 1.5
    const broadRadius = maxDim * 1.5 + radius;
    if (Math.abs(obj.x - x) > broadRadius || Math.abs(obj.y - y) > broadRadius) {
      return false;
    }

    if (obj.shape === 'circle') {
      const distSq = (x - obj.x) ** 2 + (y - obj.y) ** 2;
      const r = Math.max(obj.width, obj.length) / 2;
      const effectiveR = Math.max(0, r - clipOverlapAllowed);
      return distSq <= (effectiveR + radius) ** 2;
    } else if (obj.shape === 'rect') {
      let testX = x;
      let testY = y;

      if (obj.rotation) {
        const angle = -obj.rotation * Math.PI / 180;
        const bdx = x - obj.x;
        const bdy = y - obj.y;
        testX = obj.x + bdx * Math.cos(angle) - bdy * Math.sin(angle);
        testY = obj.y + bdx * Math.sin(angle) + bdy * Math.cos(angle);
      }

      const halfW = Math.max(0, (obj.width / 2) - clipOverlapAllowed);
      const halfL = Math.max(0, (obj.length / 2) - clipOverlapAllowed);
      const rectLeft = obj.x - halfW;
      const rectRight = obj.x + halfW;
      const rectTop = obj.y - halfL;
      const rectBottom = obj.y + halfL;

      const closestX = Math.max(rectLeft, Math.min(testX, rectRight));
      const closestY = Math.max(rectTop, Math.min(testY, rectBottom));

      const distSq = (testX - closestX) ** 2 + (testY - closestY) ** 2;
      return distSq <= radius * radius;
    }
    return false;
  }

  /**
   * Detects which collision objects in the given list overlap with the specified coordinates and radius.
   * @param {Array} objectsList - List of collision/interactive objects to check against.
   * @param {Array} coordsArray - Array of {x, y} coordinate objects to test for overlaps.
   * @param {number} [radius=0] - The collision radius around the coords to expand testing bounds.
   * @returns {Array} List of objects that intersect with the given coordinates.
   */
  findObjectsAt(objectsList, coordsArray, radius = 0) {
    const foundObjects = [];
    for (const obj of (objectsList || [])) {
      for (const { x, y } of coordsArray) {
        if (this.checkObjectOverlap(obj, x, y, radius, 0)) {
          foundObjects.push(obj);
          break; // Avoid pushing same object multiple times if large radius intersects multiple coords
        }
      }
    }
    return foundObjects;
  }

  /**
   * Evaluates whether a certain movement displacement is valid, factoring in map boundaries
   * and the `clip` permissions of all collision shapes in the world.
   * @param {Array} objectsList - List of map objects to test clipping against.
   * @param {number} newX - The target X coordinate.
   * @param {number} newY - The target Y coordinate.
   * @param {number} playerRadius - The collision radius of the moving entity.
   * @param {number} mapW - The total map width.
   * @param {number} mapH - The total map height.
   * @returns {boolean} True if the entity can move to the new coordinates, otherwise false.
   */
  canMoveTo(objectsList, newX, newY, playerRadius, mapW, mapH) {
    // Check map boundaries
    if (mapW && mapH) {
      const halfMapW = mapW / 2;
      const halfMapH = mapH / 2;
      if (newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
        newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH) {
        return false;
      }
    }

    // Check clipping
    for (const obj of objectsList) {
      if (obj.clip === undefined) obj.clip = 10;
      const clipOverlapAllowed = obj.clip;

      if (clipOverlapAllowed === -1) continue; // Completely noclip

      // Because checkObjectOverlap uses strictly <= for radius evaluation, and canMoveTo was using < for radius * radius,
      // we do not need to alter our radius here.
      if (this.checkObjectOverlap(obj, newX, newY, playerRadius - 0.0001, clipOverlapAllowed)) {
        return false; // Point inside collision object
      }
    }

    return true;
  }
}

export const physicsEngine = new PhysicsEngine();
