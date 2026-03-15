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
    
    // Memory recycled arrays to avoid GC pauses during physics loops
    this._movementCoords = [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }];
    this._exactCoords = [{ x: 0, y: 0 }];
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
   * Finds characters from a list that are within their interaction_radius of coordinates x and y.
   * @param {Array} charactersList - The list of characters/NPCs to check.
   * @param {number} x - Target X coordinate.
   * @param {number} y - Target Y coordinate.
   * @param {string} [ignoreId=null] - Character ID to ignore (usually the player's ID).
   * @returns {Array} List of characters found within the radius.
   */
  findCharacters(charactersList, x, y, ignoreId = null) {
    const found = [];
    if (!charactersList) return found;

    for (let i = 0, len = charactersList.length; i < len; i++) {
      const c = charactersList[i];
      if (ignoreId && c.id === ignoreId) continue;

      const dx = x - c.x;
      const dy = y - c.y;
      const distSq = dx * dx + dy * dy;

      const rSq = c.interaction_radius ? (c.interaction_radius * c.interaction_radius) : 150 * 150;

      if (distSq <= rSq) {
        c._distSq = distSq; // Attach for sorting if needed
        found.push(c);
      }
    }
    return found;
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
   * @param {number} mapW - The total map width.
   * @param {number} mapH - The total map height.
   * @param {Array} npcList - Optional list of NPCs to check collision against
   * @param {string|number} entityId - The ID of the moving entity (to avoid self-collision)
   * @returns {boolean} True if the entity can move to the new coordinates, otherwise false.
   */
  canMoveTo(objectsList, newX, newY, playerRadius, mapW, mapH, npcList = null, entityId = null) {
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

    if (npcList) {
      // Entities are treated as circles for simplistic collision
      const collideDistSq = (playerRadius * 2) * (playerRadius * 2);
      for (let i = 0, len = npcList.length; i < len; i++) {
        const npc = npcList[i];
        if (entityId && npc.id === entityId) continue;
        const dx = newX - npc.x;
        const dy = newY - npc.y;
        if (dx * dx + dy * dy < collideDistSq) {
          return false;
        }
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

  /**
   * Processes requested movement vectors for a given entity constraint, testing clipping masks
   * and objects, allowing sliding alongside hitboxes automatically.
   * 
   * @param {Object} entity - The character object trying to move (expects x, y, rotation properties)
   * @param {number} dx - The requested X step delta
   * @param {number} dy - The requested Y step delta
   * @param {Array} objectsList - Application state objects list 
   * @param {Object} mapData - Application state map data
   * @param {boolean} isEmoteForced - True if movement is forced by an emote (disables sliding)
   * @param {Array} npcList - Application state npcs list
   * @returns {Object} Data about the completed movement and collisions { newX, newY, actuallyInObject, isMoving, emoteCanceled }
   */
  processMovement(entity, dx, dy, objectsList, mapData, isEmoteForced = false, npcList = null) {
    let result = {
      newX: entity.x,
      newY: entity.y,
      actuallyInObject: null,
      isMoving: false,
      emoteCanceled: false
    };

    if (dx === 0 && dy === 0) return result;
    
    result.isMoving = true;

    const scale = mapData?.character_scale || 1;
    const playerRadius = 15 * scale; // slightly smaller than half width

    this._movementCoords[0].x = entity.x + dx;
    this._movementCoords[0].y = entity.y + dy;
    this._movementCoords[1].x = entity.x + dx;
    this._movementCoords[1].y = entity.y;
    this._movementCoords[2].x = entity.x;
    this._movementCoords[2].y = entity.y + dy;

    const possibleOverlaps = this.findObjectsAt(objectsList, this._movementCoords, playerRadius);

    const mapW = mapData?.width;
    const mapH = mapData?.height;

    // Try moving in both axes, then X only, then Y only (sliding against walls)
    if (isEmoteForced) {
      if (this.canMoveTo(possibleOverlaps, entity.x + dx, entity.y + dy, playerRadius, mapW, mapH, npcList, entity.id)) {
        result.newX += dx;
        result.newY += dy;
      } else {
        result.emoteCanceled = true; // Hit something while jumping!
      }
    } else {
      if (this.canMoveTo(possibleOverlaps, entity.x + dx, entity.y + dy, playerRadius, mapW, mapH, npcList, entity.id)) {
        result.newX += dx;
        result.newY += dy;
      } else {
        // Attempt Advanced Sliding Mechanism against Rotated Objects
        let hitObj = null;
        for (let i = 0; i < possibleOverlaps.length; i++) {
          const obj = possibleOverlaps[i];
          if (!obj.noclip && obj.clip !== -1 && this.checkObjectOverlap(obj, entity.x + dx, entity.y + dy, playerRadius, obj.clip === undefined ? 10 : obj.clip)) {
            hitObj = obj;
            break;
          }
        }

        if (hitObj && hitObj.shape === 'rect' && hitObj.rotation) {
          // Slide along the rotated edge
          const angle = -hitObj.rotation * (Math.PI / 180);
          const cosA = Math.cos(angle);
          const sinA = Math.sin(angle);

          // Transform intended movement vector into local space of the rotated object
          const localDx = dx * cosA - dy * sinA;
          const localDy = dx * sinA + dy * cosA;

          // Test local X sliding
          const testLocalDx = localDx;
          const testLocalDy = 0;

          // Transform back to world space
          let slideWorldDx = testLocalDx * cosA + testLocalDy * sinA;
          let slideWorldDy = -testLocalDx * sinA + testLocalDy * cosA;

          if (this.canMoveTo(possibleOverlaps, entity.x + slideWorldDx, entity.y + slideWorldDy, playerRadius, mapW, mapH, npcList, entity.id)) {
            result.newX += slideWorldDx;
            result.newY += slideWorldDy;
          } else {
            // Test local Y sliding
            const testLocalDx2 = 0;
            const testLocalDy2 = localDy;
            slideWorldDx = testLocalDx2 * cosA + testLocalDy2 * sinA;
            slideWorldDy = -testLocalDx2 * sinA + testLocalDy2 * cosA;

            if (this.canMoveTo(possibleOverlaps, entity.x + slideWorldDx, entity.y + slideWorldDy, playerRadius, mapW, mapH, npcList, entity.id)) {
              result.newX += slideWorldDx;
              result.newY += slideWorldDy;
            } else if (this.canMoveTo(possibleOverlaps, entity.x + dx, entity.y, playerRadius, mapW, mapH, npcList, entity.id)) {
              // Fallback to pure X
              result.newX += dx;
            } else if (this.canMoveTo(possibleOverlaps, entity.x, entity.y + dy, playerRadius, mapW, mapH, npcList, entity.id)) {
              // Fallback to pure Y
              result.newY += dy;
            }
          }
        } else {
          // Fallback to standard axis-aligned sliding
          if (this.canMoveTo(possibleOverlaps, entity.x + dx, entity.y, playerRadius, mapW, mapH, npcList, entity.id)) {
            result.newX += dx;
          } else if (this.canMoveTo(possibleOverlaps, entity.x, entity.y + dy, playerRadius, mapW, mapH, npcList, entity.id)) {
            result.newY += dy;
          }
        }
      }
    }

    if (possibleOverlaps.length > 0) {
      this._exactCoords[0].x = result.newX;
      this._exactCoords[0].y = result.newY;
      const matchedArray = this.findObjectsAt(possibleOverlaps, this._exactCoords, 0);
      if (matchedArray.length > 0) {
        result.actuallyInObject = matchedArray[0];
      }
    }

    return result;
  }

  /**
   * Smoothly interpolates an entity's local position and rotation towards its target coordinates dictated by the server.
   * Handles dynamic catchup speed boosting and shortest-angle rotation.
   * @param {Object} c - The character/entity object to interpolate. Expects x,y,rotation and target equivalents.
   * @param {string} [ignoreId=null] - Character ID to prevent processing (usually local player).
   */
  processInterpolation(c, ignoreId = null, timeScale = 1) {
    if (ignoreId && c.id === ignoreId) return;

    if (c.targetX !== undefined && c.targetY !== undefined) {
      const cdx = c.targetX - c.x;
      const cdy = c.targetY - c.y;
      const distSq = cdx * cdx + cdy * cdy;

      // Snap if teleported really far (100^2 = 10000)
      if (distSq > 10000) {
        c.x = c.targetX;
        c.y = c.targetY;
        c.rotation = c.targetRotation;
      } else if (distSq > 0.1) {
        // Continuous pursuit velocity based on base speed (with a dynamic catchup boost if far behind)
        const distance = Math.sqrt(distSq);
        const baseSpeed = c.moveSpeed || 3;

        // If distance is large (e.g. > 40px), temporarily boost speed so they catch up seamlessly
        const catchupMultiplier = distance > 40 ? 1.5 : 1.0;
        let stepDist = baseSpeed * catchupMultiplier * timeScale;

        // Don't overshoot the target
        if (stepDist > distance) {
          stepDist = distance;
        }

        const ratio = stepDist / distance;
        c.x += cdx * ratio;
        c.y += cdy * ratio;

        c.legAnimationTime = (c.legAnimationTime || 0) + 0.2 * timeScale;
      } else {
        c.x = c.targetX;
        c.y = c.targetY;
        c.legAnimationTime = 0; // stop moving legs when we catch up
      }

      // Interpolate rotation efficiently via shortest angle (even if not moving XY)
      if (c.targetRotation !== undefined) {
        let rotDiff = c.targetRotation - (c.rotation || 0);
        while (rotDiff > 180) rotDiff -= 360;
        while (rotDiff < -180) rotDiff += 360;

        if (Math.abs(rotDiff) > 1) {
          const rotSpeed = c.rotationSpeed || 5;
          const rotStep = Math.min(Math.abs(rotDiff), rotSpeed * timeScale);
          c.rotation = (c.rotation || 0) + Math.sign(rotDiff) * rotStep;
        } else {
          c.rotation = c.targetRotation;
        }
      }
    }
  }

  /**
   * Scans for the closest valid interactive NPC within an interaction radius and manages
   * the triggering of `on_enter` and `on_exit` handlers for the active NPC.
   * @param {Object} player - The player entity.
   * @param {Object} initData - The `window.init` layout data including NPCs and Characters.
   * @param {string|number|null} activeNpcId - The globally tracked ID of the currently active NPC.
   * @param {Object} uiManager - The global uiManager for clearing interface state when walking away.
   * @param {Function} processEventsFn - The global processEvents orchestration callback.
   * @returns {string|number|null} The new active NPC ID.
   */
  processInteractions(player, initData, activeNpcId, uiManager, processEventsFn) {
    if (!initData) return activeNpcId;

    let closestNpc = null;
    let minNpcDistSq = Infinity;

    const allInRange = [
      ...this.findCharacters(initData.characters, player.x, player.y, player.id),
      ...this.findCharacters(initData.npcs, player.x, player.y, player.id)
    ];

    for (let i = 0; i < allInRange.length; i++) {
      const c = allInRange[i];
      if (!c.isNpc && (c.on_enter === undefined && c.on_exit === undefined)) continue;

      if (c._distSq < minNpcDistSq) {
        minNpcDistSq = c._distSq;
        closestNpc = c;
      }
    }

    if (activeNpcId && (!closestNpc || activeNpcId !== closestNpc.id)) {
      const prevNpc = [...(initData.characters || []), ...(initData.npcs || [])].find(c => c.id === activeNpcId);
      if (prevNpc) {
        if (prevNpc.activeAudio) {
          prevNpc.activeAudio.pause();
          prevNpc.activeAudio.currentTime = 0;
          prevNpc.activeAudio = null;
        }
        if (prevNpc && prevNpc.on_exit && (typeof prevNpc.on_exit === 'number' || prevNpc.on_exit.length > 0)) {
          processEventsFn(prevNpc, prevNpc.on_exit, 'on_exit');
        }
        // Auto-clear avatar when walking away from an NPC
        const container = uiManager.avatarsContainer;
        if (container) {
          const el = container.querySelector(`[data-npc-id="${prevNpc.id}"]`);
          if (el) el.remove();
          if (container.children.length === 0) {
            const actionDialog = document.getElementById('top-center-ui');
            if (actionDialog) actionDialog.classList.remove('avatar-active');
            const mapNameDisplay = uiManager.mapNameDisplay;
            if (mapNameDisplay && mapNameDisplay.dataset.originalName) {
              mapNameDisplay.textContent = mapNameDisplay.dataset.originalName;
              delete mapNameDisplay.dataset.originalName;
            }
          }
        }
      }
      activeNpcId = null;
    }

    if (closestNpc && activeNpcId !== closestNpc.id) {
      activeNpcId = closestNpc.id;
      if (closestNpc.on_enter && (typeof closestNpc.on_enter === 'number' || closestNpc.on_enter.length > 0)) {
        processEventsFn(closestNpc, closestNpc.on_enter, 'on_enter');
      }
    }

    return activeNpcId;
  }
}

export const physicsEngine = new PhysicsEngine();
