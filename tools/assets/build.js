import { processOverlays } from './create_overlays.js';
import { ensureMapChunks } from './slice_maps.js';
import { ensureMinimaps } from './generate_minimaps.js';

async function build() {
    try {
        console.log("Starting map and asset pre-build...");
        await processOverlays();
        await ensureMapChunks();
        await ensureMinimaps();
        console.log("Pre-build completed successfully.");
        process.exit(0);
    } catch (e) {
        console.error("Pre-build failed:", e);
        process.exit(1);
    }
}

build();
