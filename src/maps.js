export class MapManager {
  constructor() {
    this.layers = [];
    this.mapW = 0;
    this.mapH = 0;
  }

  /**
   * Initializes the current map layers, handling dynamic chunking structure creation or 
   * loading legacy static full-map background images.
   * @param {Object} mapMetadata - The map data received from the server containing layers.
   */
  init(mapMetadata) {
    this.layers = [];
    this.mapW = mapMetadata?.width || 0;
    this.mapH = mapMetadata?.height || 0;

    if (mapMetadata.layers) {
      mapMetadata.layers.forEach((layerGroup, index) => {
        const layersList = [];
        layerGroup.forEach(layerData => {
          if (layerData.chunked) {
            console.log(`[Map Loader] Initializing chunked architecture for: ${layerData.path_template}`);
            layersList.push({
              chunked: true,
              alpha: layerData.alpha !== undefined ? layerData.alpha : 1,
              chunk_size: layerData.chunk_size,
              grid_w: layerData.grid_w,
              grid_h: layerData.grid_h,
              path_template: layerData.path_template,
              // Use a 1D flat array to absolutely avoid string allocation in dictionaries
              chunks: new Array(layerData.grid_w * layerData.grid_h)
            });
          } else {
            const img = new Image();
            img.crossOrigin = 'anonymous'; // Help with iOS strict permissions
            const layerObj = { chunked: false, image: img, alpha: layerData.alpha !== undefined ? layerData.alpha : 1 };
            layersList.push(layerObj);

            img.onload = () => {
              console.log(`[Map Loader] Finished loading layer natively: ${layerData.image}`);
            };
            img.onerror = () => {
              console.warn(`[Map Loader] Failed to load layer directly: ${layerData.image}`);
            };

            console.log(`[Map Loader] Assigning layer src synchronously: ${layerData.image}`);
            img.src = layerData.image;
          }
        });
        this.layers[index] = layersList;
      });
    }
  }

  /**
   * Renders a specific z-index layer of the current map background.
   * If the layer is defined as 'chunked', it dynamically calculates which 512x512 tiles
   * intersect the player's view camera, loads them on the fly if necessary, and renders them.
   * @param {number} layerIndex - The index of the layer stack to draw.
   * @param {CanvasRenderingContext2D} ctx - The canvas graphics context to render into.
   * @param {HTMLCanvasElement} canvas - The canvas element used to get active resolution.
   * @param {number} cameraX - player camera X
   * @param {number} cameraY - player camera Y
   * @param {number} cameraZoom - player camera Zoom
   */
  drawLayer(layerIndex, ctx, canvas, cameraX, cameraY, cameraZoom, viewportWidth, viewportHeight) {
    if (!this.layers || !this.layers[layerIndex]) return;

    if (this.mapW === 0 || this.mapH === 0) {
      if (this.layers && this.layers[0]) {
        for (const layer of this.layers[0]) {
          if (!layer.chunked && layer.image.complete) {
            this.mapW = Math.max(this.mapW, layer.image.width || 0);
            this.mapH = Math.max(this.mapH, layer.image.height || 0);

            // if we determined it dynamically, ensure it updates in window.init if needed globally
            if (window.init?.mapData) {
              window.init.mapData.width = this.mapW;
              window.init.mapData.height = this.mapH;
            }
          }
        }
      }
    }

    const halfMapW = this.mapW / 2;
    const halfMapH = this.mapH / 2;

    // Calculate active camera boundaries (in map coordinates) once
    const viewHalfW = (viewportWidth / cameraZoom) / 2;
    const viewHalfH = (viewportHeight / cameraZoom) / 2;
    const cameraLeft = cameraX - viewHalfW;
    const cameraRight = cameraX + viewHalfW;
    const cameraTop = cameraY - viewHalfH;
    const cameraBottom = cameraY + viewHalfH;

    // Add a 1-chunk buffer so we load slightly out of frame before they walk into it
    // We assume all chunked layers use the same chunk_size for the buffer computation
    // For safety, let's just use a fixed buffer heuristic or compute it based on the first chunked layer.
    let buffer = 512;
    if (this.layers[layerIndex] && this.layers[layerIndex].length > 0) {
      const firstChunked = this.layers[layerIndex].find(l => l.chunked);
      if (firstChunked) buffer = firstChunked.chunk_size;
    }

    const minXMap = Math.max(-halfMapW, cameraLeft - buffer);
    const maxXMap = Math.min(halfMapW, cameraRight + buffer);
    const minYMap = Math.max(-halfMapH, cameraTop - buffer);
    const maxYMap = Math.min(halfMapH, cameraBottom + buffer);

    const mapStartX = minXMap + halfMapW;
    const mapEndX = maxXMap + halfMapW;
    const mapStartY = minYMap + halfMapH;
    const mapEndY = maxYMap + halfMapH;

    this.layers[layerIndex].forEach(layer => {
      const prevAlpha = ctx.globalAlpha;
      if (layer.alpha !== 1) {
        ctx.globalAlpha = layer.alpha;
      }

      if (layer.chunked) {
        // --- Spatial Chunking Logic ---

        const startCol = Math.max(0, (mapStartX / layer.chunk_size) | 0);
        const endCol = Math.min(layer.grid_w - 1, (mapEndX / layer.chunk_size) | 0);
        const startRow = Math.max(0, (mapStartY / layer.chunk_size) | 0);
        const endRow = Math.min(layer.grid_h - 1, (mapEndY / layer.chunk_size) | 0);

        // Precalculate base draw offsets
        const baseY = -halfMapH | 0;
        const baseX = -halfMapW | 0;

        // Loop over only the visible tiles
        for (let y = startRow; y <= endRow; y++) {
          const drawY = (baseY + (y * layer.chunk_size)) | 0;
          for (let x = startCol; x <= endCol; x++) {
            const chunkIndex = y * layer.grid_w + x;

            if (!layer.chunks[chunkIndex]) {
              // Lazy load the chunk if it's never been seen
              const img = new Image();
              img.crossOrigin = 'anonymous';
              img.onerror = () => console.warn(`[Chunk Loader] Failed to load chunk at ${x},${y}`);

              // Generate path /grounds/chunks/background_X_Y.jpg
              const src = layer.path_template.replace('{x}', x).replace('{y}', y);
              img.src = src;

              layer.chunks[chunkIndex] = { img, cx: x, cy: y };
            }

            const chunkData = layer.chunks[chunkIndex];

            if (chunkData.img.complete && chunkData.img.naturalWidth > 0) {
              // Fast truncating for hardware integer drawing
              const drawX = (baseX + (x * layer.chunk_size)) | 0;
              
              if (cameraZoom === 1) {
                // Fast-path natively for 1.0x maps (e.g., Junior School)
                ctx.drawImage(chunkData.img, drawX, drawY);
              } else {
                // If scaled (e.g., Main Building 0.75x), HTML5 Canvas anti-aliases sub-pixel 
                // edges which causes mathematically transparent bleed lines between seams.
                // We physically draw the tile +1 pixel larger to forcefully overlap the seam!
                ctx.drawImage(chunkData.img, drawX, drawY, layer.chunk_size + 1, layer.chunk_size + 1);
              }
            }
          }
        }

        // --- Memory Cleanup: Unload out-of-frame chunks ---
        if (!layer.gcTick) layer.gcTick = 0;
        layer.gcTick++;

        // Only run garbage collection sweep once per 600 frames (approx every 10 seconds)
        if (layer.gcTick > 600) {
          layer.gcTick = 0;
          const gcBuffer = 2; // Unload chunks that are 2 chunks away from view bounds
          for (let i = 0; i < layer.chunks.length; i++) {
            const chunkData = layer.chunks[i];
            if (!chunkData) continue;
            if (chunkData.cx < startCol - gcBuffer || chunkData.cx > endCol + gcBuffer ||
              chunkData.cy < startRow - gcBuffer || chunkData.cy > endRow + gcBuffer) {
              // Nullify handlers before changing src to prevent false positive onerror logs
              chunkData.img.onload = null;
              chunkData.img.onerror = null;
              // Nullify image source to free memory, then delete from cache
              chunkData.img.src = '';
              layer.chunks[i] = null;
            }
          }
        }
      } else {
        // --- Standard Legacy Image Rendering ---
        if (layer.image.complete && layer.image.naturalWidth > 0) {
          const hw = layer.image.width >> 1;
          const hh = layer.image.height >> 1;
          ctx.drawImage(layer.image, -hw, -hh);
        }
      }

      // Cleanup global transparency override without relying on the matrix stack
      if (layer.alpha !== 1) {
        ctx.globalAlpha = prevAlpha;
      }
    });
  }
}

export const mapManager = new MapManager();
