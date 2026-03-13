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
    
    console.log('Map layers: ', mapMetadata.layers);

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
              chunks: {} // Memory object to store individual lazily loaded tiles
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
  drawLayer(layerIndex, ctx, canvas, cameraX, cameraY, cameraZoom) {
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

    this.layers[layerIndex].forEach(layer => {
      ctx.save();
      ctx.globalAlpha = layer.alpha;
      
      if (layer.chunked) {
        // --- Spatial Chunking Logic ---
        
        // Calculate active camera boundaries (in map coordinates)
        const viewHalfW = (canvas.width / cameraZoom) / 2;
        const viewHalfH = (canvas.height / cameraZoom) / 2;
        
        const cameraLeft = cameraX - viewHalfW;
        const cameraRight = cameraX + viewHalfW;
        const cameraTop = cameraY - viewHalfH;
        const cameraBottom = cameraY + viewHalfH;

        // Add a 1-chunk buffer so we load slightly out of frame before they walk into it
        const buffer = layer.chunk_size;
        const minXMap = Math.max(-halfMapW, cameraLeft - buffer);
        const maxXMap = Math.min(halfMapW, cameraRight + buffer);
        const minYMap = Math.max(-halfMapH, cameraTop - buffer);
        const maxYMap = Math.min(halfMapH, cameraBottom + buffer);

        // Convert map bounds to strict chunk grid indices [0 ... grid_w-1]
        // Important: minXMap ranges from -halfMapW to +halfMapW. We need to normalize to 0..mapW
        const mapStartX = minXMap + halfMapW;
        const mapEndX = maxXMap + halfMapW;
        const mapStartY = minYMap + halfMapH;
        const mapEndY = maxYMap + halfMapH;

        const startCol = Math.max(0, Math.floor(mapStartX / layer.chunk_size));
        const endCol = Math.min(layer.grid_w - 1, Math.floor(mapEndX / layer.chunk_size));
        const startRow = Math.max(0, Math.floor(mapStartY / layer.chunk_size));
        const endRow = Math.min(layer.grid_h - 1, Math.floor(mapEndY / layer.chunk_size));

        // Loop over only the visible tiles
        for (let y = startRow; y <= endRow; y++) {
          for (let x = startCol; x <= endCol; x++) {
            const chunkKey = `${x}_${y}`;
            
            if (!layer.chunks[chunkKey]) {
              // Lazy load the chunk if it's never been seen
              const img = new Image();
              img.crossOrigin = 'anonymous';
              img.onerror = () => console.warn(`[Chunk Loader] Failed to load chunk: ${chunkKey}`);
              
              // Generate path /grounds/chunks/background_X_Y.jpg
              const src = layer.path_template.replace('{x}', x).replace('{y}', y);
              img.src = src;
              
              layer.chunks[chunkKey] = img;
            }

            const chunkImg = layer.chunks[chunkKey];
            
            if (chunkImg.complete && chunkImg.naturalWidth > 0) {
              // Map grid coordinates back to world offset coordinates (-halfMapW to +halfMapW)
              const drawX = Math.floor(-halfMapW + (x * layer.chunk_size));
              const drawY = Math.floor(-halfMapH + (y * layer.chunk_size));
              ctx.drawImage(chunkImg, drawX, drawY, layer.chunk_size + 1, layer.chunk_size + 1);
            }
          }
        }

        // --- Memory Cleanup: Unload out-of-frame chunks ---
        const gcBuffer = 2; // Unload chunks that are 2 chunks away from view bounds
        for (const key of Object.keys(layer.chunks)) {
          const [cx, cy] = key.split('_').map(Number);
          if (cx < startCol - gcBuffer || cx > endCol + gcBuffer || 
              cy < startRow - gcBuffer || cy > endRow + gcBuffer) {
            // Nullify image source to free memory, then delete from cache
            layer.chunks[key].src = '';
            delete layer.chunks[key];
          }
        }
      } else {
        // --- Standard Legacy Image Rendering ---
        if (layer.image.complete && layer.image.naturalWidth > 0) {
          ctx.drawImage(layer.image, -layer.image.width / 2, -layer.image.height / 2);
        }
      }
      ctx.restore();
    });
  }
}

export const mapManager = new MapManager();
