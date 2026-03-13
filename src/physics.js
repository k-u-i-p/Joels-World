export class PhysicsEngine {
  /**
   * Helper function to detect if a specific coordinate and radius overlaps with a collision object.
   * Applies rotated rectangle math and bounding circle math perfectly.
   * Optimized to avoid allocations and use primitive math faster than Math.max/min.
   * @param {Object} obj - The map object to test against.
   * @param {number} x - The target X coordinate.
   * @param {number} y - The target Y coordinate.
   * @param {number} radius - The collision radius around the coords.
   * @param {number} [clipOverlapAllowed=0] - How much overlap is allowed
   * @returns {boolean} True if the entity point overlaps the object bounds.
   */
  checkObjectOverlap(obj, x, y, radius, clipOverlapAllowed = 0) {
    const w = obj.width || 0;
    const l = obj.length || 0;
    const maxDimHalf = (w > l ? w : l) * 0.5;

    // Local delta coordinates
    const dx = x - obj.x;
    const dy = y - obj.y;

    // Broad-phase AABB rejection
    const broadRadius = maxDimHalf * 1.415 + radius;
    // Fast absolute value comparisons
    if (dx > broadRadius || dx < -broadRadius || dy > broadRadius || dy < -broadRadius) {
      return false;
    }

    if (obj.shape === 'circle') {
      let effectiveR = maxDimHalf - clipOverlapAllowed;
      if (effectiveR < 0) effectiveR = 0;
      effectiveR += radius;
      return (dx * dx + dy * dy) <= (effectiveR * effectiveR);
    } else if (obj.shape === 'rect') {
      let testX, testY;

      if (obj.rotation) {
        // Precomputed Math.PI / 180 = 0.017453292519943295
        const angle = -obj.rotation * 0.017453292519943295;
        const cosA = Math.cos(angle);
        const sinA = Math.sin(angle);
        testX = dx * cosA - dy * sinA;
        testY = dx * sinA + dy * cosA;
      } else {
        testX = dx;
        testY = dy;
      }

      let halfW = w * 0.5 - clipOverlapAllowed;
      if (halfW < 0) halfW = 0;
      let halfL = l * 0.5 - clipOverlapAllowed;
      if (halfL < 0) halfL = 0;

      let closestX = testX;
      if (closestX < -halfW) closestX = -halfW;
      else if (closestX > halfW) closestX = halfW;

      let closestY = testY;
      if (closestY < -halfL) closestY = -halfL;
      else if (closestY > halfL) closestY = halfL;

      const distX = testX - closestX;
      const distY = testY - closestY;

      return (distX * distX + distY * distY) <= (radius * radius);
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
    if (!objectsList || !coordsArray) return foundObjects;

    for (let i = 0, len = objectsList.length; i < len; i++) {
      const obj = objectsList[i];
      for (let j = 0, cLen = coordsArray.length; j < cLen; j++) {
        const pt = coordsArray[j];
        if (this.checkObjectOverlap(obj, pt.x, pt.y, radius, 0)) {
          foundObjects.push(obj);
          break; // Avoid pushing same object multiple times
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
    // Check map boundaries efficiently
    if (mapW && mapH) {
      const halfMapW = mapW * 0.5;
      const halfMapH = mapH * 0.5;
      if (
        newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
        newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH
      ) {
        return false;
      }
    }

    if (!objectsList) return true;

    // Optimized looping structure inline
    const testRadius = playerRadius - 0.0001;
    for (let i = 0, len = objectsList.length; i < len; i++) {
      const obj = objectsList[i];

      // If the object overrides noclip internally
      if (obj.noclip) continue;

      let clipOverlapAllowed = obj.clip;
      if (clipOverlapAllowed === undefined) clipOverlapAllowed = 10;
      if (clipOverlapAllowed === -1) continue; // Completely noclip

      if (this.checkObjectOverlap(obj, newX, newY, testRadius, clipOverlapAllowed)) {
        return false; // Point inside collision object
      }
    }

    return true;
  }
}

export const physicsEngine = new PhysicsEngine();
