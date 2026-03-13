import sharp from 'sharp';
import fs from 'fs';
import path from 'path';

// Define the maps and layers to chunk
const CHUNK_SIZE = 512;
const MAPS_TO_CHUNK = [
  {
    folder: 'grounds',
    layers: ['background.jpg', 'trees.png'] // Note: trees is a transparent PNG
  }
];

const basePath = path.resolve('./public');

async function processLayer(folder, filename) {
  const inputPath = path.join(basePath, folder, filename);
  const chunksDir = path.join(basePath, folder, 'chunks');

  if (!fs.existsSync(inputPath)) {
    console.warn(`[Skip] Missing file: ${inputPath}`);
    return;
  }

  // Create chunks directory if it doesn't exist
  if (!fs.existsSync(chunksDir)) {
    fs.mkdirSync(chunksDir, { recursive: true });
  }

  try {
    const image = sharp(inputPath);
    const metadata = await image.metadata();
    
    const width = metadata.width;
    const height = metadata.height;
    
    const gridW = Math.ceil(width / CHUNK_SIZE);
    const gridH = Math.ceil(height / CHUNK_SIZE);

    console.log(`\nSlicing ${folder}/${filename} (${width}x${height}) into ${gridW}x${gridH} chunks...`);

    const extractPromises = [];
    let chunkCount = 0;

    // Use .png for transparent layers, .jpg for solid backgrounds based on input
    const isPng = filename.endsWith('.png');
    const ext = isPng ? '.png' : '.jpg';
    const baseName = filename.substring(0, filename.lastIndexOf('.'));

    for (let y = 0; y < gridH; y++) {
      for (let x = 0; x < gridW; x++) {
        const left = x * CHUNK_SIZE;
        const top = y * CHUNK_SIZE;
        
        // Handle edges that might be smaller than CHUNK_SIZE
        const extractWidth = Math.min(CHUNK_SIZE, width - left);
        const extractHeight = Math.min(CHUNK_SIZE, height - top);

        const outputPath = path.join(chunksDir, `${baseName}_${x}_${y}${ext}`);

        let extractor = image.clone().extract({ left, top, width: extractWidth, height: extractHeight });
        
        // Preserve transparency for PNGs, optimize JPGs
        if (isPng) {
          extractor = extractor.png();
        } else {
          extractor = extractor.jpeg({ quality: 85 });
        }

        extractPromises.push(
          extractor.toFile(outputPath).then(() => {
            chunkCount++;
            process.stdout.write(`\rProgress: ${chunkCount}/${gridW * gridH} chunks saved.`);
          })
        );
      }
    }

    await Promise.all(extractPromises);
    
    console.log(`\n[Success] Sliced ${folder}/${filename}!`);
    console.log(`Expected maps.json metadata:`);
    console.log(`"chunked": true,`);
    console.log(`"chunk_size": ${CHUNK_SIZE},`);
    console.log(`"grid_w": ${gridW},`);
    console.log(`"grid_h": ${gridH},`);
    console.log(`"path_template": "/${folder}/chunks/${baseName}_{x}_{y}${ext}"`);
    
  } catch (err) {
    console.error(`\n[Error] Failed processing ${inputPath}:`, err);
  }
}

async function run() {
  for (const map of MAPS_TO_CHUNK) {
    for (const layer of map.layers) {
      await processLayer(map.folder, layer);
    }
  }
  console.log('\nAll slicing complete!');
}

run();
