import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { pathToFileURL } from 'url';
import { assetPath, assetRelative, readMaps } from './paths.js';

export async function processOverlays() {
  console.log('[OverlayGen] Starting overlay generation process...');

  const mapsData = readMaps('[OverlayGen]');
  if (!mapsData) return;

  for (const map of mapsData) {
    if (!map.clip_mask || !map.layers) continue;

    const clipMaskRel = assetRelative(map.clip_mask);
    const clipMaskPath = assetPath(clipMaskRel);

    if (!fs.existsSync(clipMaskPath)) {
      console.warn(`[OverlayGen] Map "${map.name}" defines a clip_mask but the file is missing: ${clipMaskPath}`);
      continue;
    }

    console.log(`\n[OverlayGen] Processing map: "${map.name}" utilizing mask: ${clipMaskRel}`);

    for (const layer of map.layers) {
        if (!layer.source_image || layer.overlay || layer.source_image.includes('_overlay.')) continue;

        const sourceRel = assetRelative(layer.source_image);
        const sourcePath = assetPath(sourceRel);

        if (!fs.existsSync(sourcePath)) {
          console.warn(`[OverlayGen] Layer source image missing, skipping: ${sourcePath}`);
          continue;
        }

        const parsedSource = path.parse(sourceRel);
        const outName = `${parsedSource.name}_overlay.png`;
        const outPath = assetPath(parsedSource.dir, outName);

        if (fs.existsSync(outPath)) {
          console.log(`  -> Skipping existing overlay: ${sourceRel}`);
          continue;
        }

        console.log(`  -> Processing layer: ${sourceRel}`);

        try {
          // 1. Get dimensions of the source image
          const sourceObj = sharp(sourcePath);
          const sourceMeta = await sourceObj.metadata();

          // Ensure source has alpha channel
          const sourceBuffer = await sourceObj.ensureAlpha().raw().toBuffer();

          // 2. Load and resize the clip mask to match the source exactly
          const maskObj = sharp(clipMaskPath);
          const maskBuffer = await maskObj
            .resize(sourceMeta.width, sourceMeta.height, { fit: 'fill' })
            .ensureAlpha() // Just to be safe that we get 4 channels (RGBA)
            .raw()
            .toBuffer();

          // 3. Modifying raw pixel buffers
          // Both buffers are now RGBA format, matching byte alignment: 4 bytes per pixel.
          const totalBytes = sourceMeta.width * sourceMeta.height * 4;
          const outBuffer = Buffer.alloc(totalBytes);

          for (let i = 0; i < totalBytes; i += 4) {
            const maskR = maskBuffer[i];
            const maskG = maskBuffer[i + 1];
            const maskB = maskBuffer[i + 2];
            const maskA = maskBuffer[i + 3];

            // If pixel is mostly black and opaque... keep it! Else, transparent.
            // Also keep pure green (0, 255, 0) which players can walk behind.
            if (maskA == 255 && maskR == 0 && maskB == 0 && maskG == 0 || maskA == 255 && maskG == 255 && maskR == 0 && maskB == 0) {
              // Copy the source pixel to the output buffer
              outBuffer[i] = sourceBuffer[i];
              outBuffer[i + 1] = sourceBuffer[i + 1];
              outBuffer[i + 2] = sourceBuffer[i + 2];
              outBuffer[i + 3] = sourceBuffer[i + 3];
            }
          }

          // 4. Encode the buffer back into a PNG file
          await sharp(outBuffer, {
            raw: {
              width: sourceMeta.width,
              height: sourceMeta.height,
              channels: 4
            }
          })
            .png({
              compressionLevel: 9,
              adaptiveFiltering: true,
              effort: 10,
              palette: true
            })
            .toFile(outPath);

          console.log(`     [Success] Saved overlay: ${path.join(parsedSource.dir, outName)}`);

        } catch (err) {
          console.error(`     [Error] Failed to generate overlay for ${sourceRel}:`, err);
        }
    }
  }

  console.log('\n[OverlayGen] Finished generating overlays!');
}

// `build.js` runs all three stages; this one is also the slowest to redo by hand, so it stays
// runnable on its own with `node create_overlays.js`.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  processOverlays().catch(console.error);
}
