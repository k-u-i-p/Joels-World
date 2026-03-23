import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { threeCamera } from './main.js';

export class MapManager {
  constructor() {
    this.layers = [];
    this.mapW = 0;
    this.mapH = 0;
    this.textureLoader = new THREE.TextureLoader();
    this.textureLoader.setCrossOrigin('anonymous');
    this.gltfLoader = new GLTFLoader();
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
        mesh.traverse((child) => {
          if (child.isMesh) {
            if (child.geometry) child.geometry.dispose();
            if (child.material) {
              const materials = Array.isArray(child.material) ? child.material : [child.material];
              materials.forEach(m => {
                if (m.map) m.map.dispose();
                m.dispose();
              });
            }
          }
        });
        if (mesh.material) {
          if (mesh.material.map) mesh.material.map.dispose();
          mesh.material.dispose();
        }
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

              // Enable physical Lambert reactive lighting exclusively on the structural foundation ground layer 
              // This permits PCF Soft Shadows to cast flawlessly right onto the geographic geometry, bypassing transparent overlaps completely!
              const isGround = index === 0;
              const MaterialType = isGround ? THREE.MeshLambertMaterial : THREE.MeshBasicMaterial;

              const mat = new MaterialType({
                map: tex,
                transparent: !isGround, // Layer 0 writes sequentially to the Opaque buffers
                opacity: layerObj.alpha
              });
              layerObj.mesh = new THREE.Mesh(geom, mat);
              if (isGround) layerObj.mesh.receiveShadow = true; // Bake native geometry shadows!
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

    if (window.init && window.init.objects && scene) {
      window.init.objects.forEach(obj => {
        if (obj.shape !== '3d_model' || !obj.modelPath) return;

        const src = obj.modelPath.startsWith('/') ? obj.modelPath : '/' + obj.modelPath;
        console.log(`[Map Loader] Initializing 3D Model Object: ${src}`);

        this.gltfLoader.load(src, (gltf) => {
          const model = gltf.scene;
          const pos = obj;

          // Reset the raw imported model to a flat upright stance at 0,0,0
          model.position.set(0, 0, 0);
          model.scale.set(1, 1, 1);
          // By default Three.js GLTFLoader usually imports Y-up.
          // Because this game natively uses Z-up (threeCamera.up.set(0,0,1)),
          // rotate 90 degrees on X so the model stands upright.
          model.rotation.set(Math.PI / 2, 0, 0);
          model.updateMatrixWorld(true);

          // Calculate its physical Bounds natively
          const box = new THREE.Box3().setFromObject(model);

          // Offset the model itself so that its absolute Top-Left corner is shifted to exactly 0,0,0
          // World +Y is Top of screen (Canvas -Y). Top-Left is (min.x, max.y). Bottom is min.z.
          model.position.set(-box.min.x, -box.max.y, -box.min.z);

          // Wrap it safely over a custom pivot hook 
          const pivotGroup = new THREE.Group();
          pivotGroup.add(model);

          pivotGroup.position.set(pos.x || 0, -(pos.y || 0), pos.z || 0);

          const scale = pos.scale !== undefined ? pos.scale : 1;
          pivotGroup.scale.setScalar(scale);

          // Now safely apply horizontal orientation exclusively to the anchor hook
          const userRot = (pos.rotation || 0) * (Math.PI / 180);
          pivotGroup.rotation.z = userRot;

          pivotGroup.traverse((child) => {
            if (child.isMesh) {
              child.castShadow = true;
              child.receiveShadow = true;
            }
          });

          pivotGroup.userData = { id: obj.id };
          scene.add(pivotGroup);
          this.activeMeshes.push(pivotGroup);
        }, undefined, (err) => {
          console.error(`[Map Loader] Failed to load 3D Model at ${src}`, err);
        });
      });
    }
  }

  drawLayer(layerIndex, scene, cameraX, cameraY, cameraZoom, viewportWidth, viewportHeight, springX = 0, springY = 0) {
    if (!this.layers || !this.layers[layerIndex]) return;

    // Layer 0 is Ground (z=0). Characters natively sit at z=5.
    // Ensure that overlay layers (1, 2, etc.) render physically IN FRONT of characters by pushing them up the Z-axis.
    let baseZIndex = layerIndex * 10;
    const halfMapW = this.mapW / 2;
    const halfMapH = this.mapH / 2;

    const cornersNDC = [
      new THREE.Vector3(-1, 1, 0),
      new THREE.Vector3(1, 1, 0),
      new THREE.Vector3(1, -1, 0),
      new THREE.Vector3(-1, -1, 0)
    ];
    const raycaster = new THREE.Raycaster();
    const plane = new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);
    
    let cameraLeft = Infinity, cameraRight = -Infinity;
    let cameraTop = Infinity, cameraBottom = -Infinity;

    cornersNDC.forEach(ndc => {
      raycaster.setFromCamera(ndc, threeCamera);
      const target = new THREE.Vector3();
      const hit = raycaster.ray.intersectPlane(plane, target);
      if (hit) {
        if (target.x < cameraLeft) cameraLeft = target.x;
        if (target.x > cameraRight) cameraRight = target.x;
        if (-target.y < cameraTop) cameraTop = -target.y; 
        if (-target.y > cameraBottom) cameraBottom = -target.y;
      } else {
        // Ray aims above horizon, stretch bounds infinitely towards edge of map
        if (ndc.y > 0) cameraTop = -halfMapH;
        if (ndc.y < 0) cameraBottom = halfMapH;
        if (ndc.x < 0) cameraLeft = -halfMapW;
        if (ndc.x > 0) cameraRight = halfMapW;
      }
    });

    if (cameraLeft === Infinity) cameraLeft = -halfMapW;
    if (cameraRight === -Infinity) cameraRight = halfMapW;
    if (cameraTop === Infinity) cameraTop = -halfMapH;
    if (cameraBottom === -Infinity) cameraBottom = halfMapH;

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

              // Distinguish flat ground geometries from floating overhead masking textures
              const isOverlay = layerIndex > 0;
              const paddedGeom = this.getGeometry(layer.chunk_size);

              // Leverage Lambert lighting natively so shadows trace seamlessly ignoring transparency queues
              const MaterialType = !isOverlay ? THREE.MeshLambertMaterial : THREE.MeshBasicMaterial;
              const mat = new MaterialType({
                transparent: isOverlay,
                opacity: layer.alpha
              });
              const mesh = new THREE.Mesh(paddedGeom, mat);
              if (!isOverlay) mesh.receiveShadow = true; // Actively catch intersecting PCF matrices

              // Position the mesh tile
              const drawX = baseX + (x * layer.chunk_size);
              mesh.position.set(
                drawX + layer.chunk_size / 2,
                -(drawY + layer.chunk_size / 2),
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
                origDrawX + layer.chunk_size / 2 - springX,
                -(origDrawY + layer.chunk_size / 2 - springY),
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

  updateDynamicModels(objects) {
    if (!objects || !this.activeMeshes) return;
    this.activeMeshes.forEach(mesh => {
      if (mesh.userData && mesh.userData.id !== undefined) {
        const obj = objects.find(o => o.id === mesh.userData.id);
        if (obj) {
           mesh.position.set(obj.x || 0, -(obj.y || 0), obj.z || 0);
           const userRot = (obj.rotation || 0) * (Math.PI / 180);
           mesh.rotation.z = userRot;
           
           if (obj.scale !== undefined) {
               mesh.scale.setScalar(obj.scale);
           }
        }
      }
    });
  }

}

export const mapManager = new MapManager();
