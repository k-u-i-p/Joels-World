export class PhysicsEngine {
  constructor() {
    this.clipMaskCanvas = null;
    this.clipMaskCtx = null;
    this.clipMaskWidth = 0;
    this.clipMaskHeight = 0;
    this.clipMaskImageData = null;
    this.clipMaskScale = 0.1;
    this.mapW = 0;
    this.mapH = 0;
  }

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
   * Loads a clip_mask image/SVG and renders it to an offscreen canvas for pixel reading.
   * @param {string} url - The URL of the mask image.
   * @param {number} mapW - Map width for canvas sizing.
   * @param {number} mapH - Map height for canvas sizing.
   */
  loadClipMask(url, mapW, mapH) {
    if (!url) {
      this.clipMaskCanvas = null;
      this.clipMaskCtx = null;
      this.clipMaskImageData = null;
      return;
    }

    // Start with a small scale for the mask check to avoid excessive memory on 4K maps
    // E.g., mask scale of 1 is full res, 0.5 is half. Let's use 1 for accuracy on SVGs.
    this.mapW = mapW;
    this.mapH = mapH;

    // Crucial: Must be an integer! Floating point canvas sizes cause undefined array indices.
    this.clipMaskWidth = Math.round(mapW * this.clipMaskScale);
    this.clipMaskHeight = Math.round(mapH * this.clipMaskScale);

    const canvas = window.OffscreenCanvas ? new OffscreenCanvas(this.clipMaskWidth, this.clipMaskHeight) : document.createElement('canvas');
    if (!window.OffscreenCanvas) {
      canvas.width = this.clipMaskWidth;
      canvas.height = this.clipMaskHeight;
    }
    const ctx = canvas.getContext('2d', { willReadFrequently: true });

    // Clear to white (walkable by default)
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, this.clipMaskWidth, this.clipMaskHeight);

    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      ctx.drawImage(img, 0, 0, this.clipMaskWidth, this.clipMaskHeight);
      this.clipMaskCanvas = canvas;
      this.clipMaskCtx = ctx;
      try {
        this.clipMaskImageData = ctx.getImageData(0, 0, this.clipMaskWidth, this.clipMaskHeight).data;
        console.log(`[PhysicsEngine] Clip mask loaded successfully: ${url}`);
      } catch (e) {
        console.warn(`[PhysicsEngine] Failed to read clip_mask image data - CORS issue?`);
        this.clipMaskImageData = null;
      }
    };
    img.onerror = () => console.warn(`[PhysicsEngine] Failed to load clip_mask at ${url}`);
    img.src = url;
  }

  /**
   * Evaluates if a given map coordinate is black on the clip_mask.
   * @param {number} x - The target X coordinate.
   * @param {number} y - The target Y coordinate.
   * @param {number} playerRadius - The collision radius.
   * @returns {boolean} True if the area is walkable, false if it is masked (black).
   */
  checkClipMask(x, y, playerRadius) {
    if (!this.clipMaskImageData) return true; // Default to walkable if mask isn't loaded

    // Convert centered coordinates (-halfW to halfW) to top-left pixel coordinates (0 to W)
    // We add half the full unscaled map width to 0-index the coordinates, THEN apply the scale.
    const pixelX = Math.floor((x + (this.mapW / 2)) * this.clipMaskScale);
    const pixelY = Math.floor((y + (this.mapH / 2)) * this.clipMaskScale);

    // Bounds check
    if (pixelX < 0 || pixelX >= this.clipMaskWidth || pixelY < 0 || pixelY >= this.clipMaskHeight) {
      return false; // Out of bounds of mask entirely
    }

    // Read pixel data: index = (y * width + x) * 4
    const index = (pixelY * this.clipMaskWidth + pixelX) * 4;
    const r = this.clipMaskImageData[index];
    const g = this.clipMaskImageData[index + 1];
    const b = this.clipMaskImageData[index + 2];
    const a = this.clipMaskImageData[index + 3];

    // If pixel is mostly black and opaque, it's a solid boundary
    // Threshold can be adjusted; SVG usually renders pitch black #000000
    if (a > 0 && r < 250 && g < 250 && b < 250) {
      return false; // Cannot walk here
    }

    return true; // Walkable
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

    // Check SVG clip mask
    if (!this.checkClipMask(newX, newY, playerRadius)) {
      return false;
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
