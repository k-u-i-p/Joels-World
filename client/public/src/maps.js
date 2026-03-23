import * as THREE from 'three';

export class MapManager {
  constructor() {
    this.layers = [];
    this.mapW = 0;
    this.mapH = 0;
    this.textureLoader = new THREE.TextureLoader();
    this.textureLoader.setCrossOrigin('anonymous');
    this.planeCache = {};
    this.activeMeshes = [];
  }

  getGeometry(size) {
    if (!this.planeCache[size]) {
      this.planeCache[size] = new THREE.PlaneGeometry(size, size);
    }
    return this.planeCache[size];
  }

  init(mapMetadata, scene) {
    if (scene) {
      this.activeMeshes.forEach(mesh => {
        scene.remove(mesh);
        if (mesh.material.map) mesh.material.map.dispose();
        mesh.material.dispose();
      });
    }
    this.activeMeshes = [];
    this.layers = [];
    this.mapW = mapMetadata?.width || 0;
    this.mapH = mapMetadata?.height || 0;

    if (mapMetadata.layers) {
      mapMetadata.layers.forEach((layerGroup, index) => {
        const layersList = [];
        layerGroup.forEach(layerData => {
          if (layerData.chunked) {
            console.log(`[Map Loader] Initializing WebGL chunked architecture for: ${layerData.path_template}`);
            layersList.push({
              chunked: true,
              alpha: layerData.alpha !== undefined ? layerData.alpha : 1,
              chunk_size: layerData.chunk_size,
              grid_w: layerData.grid_w,
              grid_h: layerData.grid_h,
              path_template: layerData.path_template,
              chunks: new Array(layerData.grid_w * layerData.grid_h)
            });
          } else {
            console.log(`[Map Loader] Initializing WebGL legacy mesh for: ${layerData.image}`);
            const layerObj = { chunked: false, alpha: layerData.alpha !== undefined ? layerData.alpha : 1, imageLoaded: false };
            this.textureLoader.load(layerData.image, (tex) => {
              layerObj.texture = tex;
              layerObj.imageLoaded = true;
              this.mapW = Math.max(this.mapW, tex.image.width || 0);
              this.mapH = Math.max(this.mapH, tex.image.height || 0);

              const geom = new THREE.PlaneGeometry(tex.image.width, tex.image.height);
              const mat = new THREE.MeshBasicMaterial({ map: tex, transparent: true, opacity: layerObj.alpha });
              layerObj.mesh = new THREE.Mesh(geom, mat);
              if (scene) {
                  scene.add(layerObj.mesh);
                  this.activeMeshes.push(layerObj.mesh);
              }
            });
            layersList.push(layerObj);
          }
        });
        this.layers[index] = layersList;
      });
    }
  }

  drawLayer(layerIndex, scene, cameraX, cameraY, cameraZoom, viewportWidth, viewportHeight, springX = 0, springY = 0) {
    if (!this.layers || !this.layers[layerIndex]) return;

    // Layer 0 is Ground (z=0). Characters natively sit at z=18 and their physical 3D geometries extend up to z=60.
    // To ensure overlay map layers visually obscure the character natively via the engine Depth Buffer, they must explicitly clear Z=60!
    let baseZIndex = layerIndex === 0 ? 0 : (layerIndex * 100);
    const halfMapW = this.mapW / 2;
    const halfMapH = this.mapH / 2;

    const viewHalfW = (viewportWidth / cameraZoom) / 2;
    const viewHalfH = (viewportHeight / cameraZoom) / 2;
    const cameraLeft = cameraX - viewHalfW;
    const cameraRight = cameraX + viewHalfW;
    const cameraTop = cameraY - viewHalfH;
    const cameraBottom = cameraY + viewHalfH;

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

    this.layers[layerIndex].forEach((layer, idxLayerWithinGrid) => {
      const layerZ = baseZIndex + idxLayerWithinGrid; 

      if (layer.chunked) {
        const startCol = Math.max(0, (mapStartX / layer.chunk_size) | 0);
        const endCol = Math.min(layer.grid_w - 1, (mapEndX / layer.chunk_size) | 0);
        const startRow = Math.max(0, (mapStartY / layer.chunk_size) | 0);
        const endRow = Math.min(layer.grid_h - 1, (mapEndY / layer.chunk_size) | 0);

        const baseY = -halfMapH;
        const baseX = -halfMapW;

        for (let y = startRow; y <= endRow; y++) {
          const drawY = baseY + (y * layer.chunk_size);
          for (let x = startCol; x <= endCol; x++) {
            const chunkIndex = y * layer.grid_w + x;

            if (!layer.chunks[chunkIndex]) {
              // Generate path for the chunk texture
              const src = layer.path_template.replace('{x}', x).replace('{y}', y);
              
              // We pad the geometry very slightly to prevent aliasing seams
              const paddedGeom = this.getGeometry(layer.chunk_size + 1);
              const mat = new THREE.MeshBasicMaterial({ transparent: true, opacity: layer.alpha });
              const mesh = new THREE.Mesh(paddedGeom, mat);

              // Position the mesh tile
              const drawX = baseX + (x * layer.chunk_size);
              mesh.position.set(
                  drawX + layer.chunk_size/2, 
                  -(drawY + layer.chunk_size/2), 
                  layerZ
              );
              
              mesh.visible = false;
              scene.add(mesh);
              this.activeMeshes.push(mesh);

              layer.chunks[chunkIndex] = { mesh, cx: x, cy: y };

              this.textureLoader.load(src, (tex) => {
                  tex.minFilter = THREE.NearestFilter;
                  tex.magFilter = THREE.NearestFilter;
                  tex.wrapS = THREE.ClampToEdgeWrapping;
                  tex.wrapT = THREE.ClampToEdgeWrapping;
                  tex.colorSpace = THREE.SRGBColorSpace; // Prevent washed out colors
                  
                  mat.map = tex;
                  mat.needsUpdate = true;
                  mesh.visible = true;
              }, undefined, () => {
                  console.warn(`[Chunk Loader] Failed to load WebGL texture at ${x},${y}`);
              });
            } else {
               layer.chunks[chunkIndex].mesh.visible = true;
               
               // Layer 2 gets a Parallax spring offset
               const origDrawX = baseX + x * layer.chunk_size;
               const origDrawY = baseY + y * layer.chunk_size;
               layer.chunks[chunkIndex].mesh.position.set(
                   origDrawX + layer.chunk_size/2 - springX, 
                   -(origDrawY + layer.chunk_size/2 - springY), 
                   layerZ
               );
            }
          }
        }

        // Memory Cleanup: Visibility culling
        if (!layer.gcTick) layer.gcTick = 0;
        layer.gcTick++;
        if (layer.gcTick > 60) {
          layer.gcTick = 0;
          const gcBuffer = 2;
          for (let i = 0; i < layer.chunks.length; i++) {
            const chunkData = layer.chunks[i];
            if (!chunkData) continue;
            if (chunkData.cx < startCol - gcBuffer || chunkData.cx > endCol + gcBuffer ||
                chunkData.cy < startRow - gcBuffer || chunkData.cy > endRow + gcBuffer) {
                chunkData.mesh.visible = false;
            }
          }
        }
      } else {
        if (layer.mesh) {
            layer.mesh.position.set(-springX, springY, layerZ);
        }
      }
    });
  }
}

export const mapManager = new MapManager();
