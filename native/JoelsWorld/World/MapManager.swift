import simd

/// One chunk tile the renderer should draw this frame.
struct ChunkDraw {
    /// Server-relative texture path, e.g. `/junior_school/chunks/background_3_2.jpg`.
    let path: String
    /// Centre of the tile in *render* space (Y already negated).
    let centerX: Float
    let centerY: Float
    let z: Float
    let size: Float
    let alpha: Float
    /// Layer 0 is the opaque ground; anything above is a blended overlay.
    let isOverlay: Bool
}

/// Port of `maps.js` — resolves which chunk tiles are on screen.
///
/// Deliberately holds no Metal types so the renderer choice stays swappable (PLAN.md §2).
final class MapManager {
    private struct ChunkedLayer {
        var z: Int
        var indexWithinZ: Int
        var alpha: Float
        var chunkSize: Double
        var gridW: Int
        var gridH: Int
        var pathTemplate: String
    }

    private var layers: [ChunkedLayer] = []
    private(set) var mapWidth: Double = 0
    private(set) var mapHeight: Double = 0

    /// Distinct layer depths, ascending — the renderer draws in this order.
    private(set) var depths: [Int] = []

    func load(mapData: MapData) {
        layers.removeAll()
        mapWidth = mapData.width
        mapHeight = mapData.height

        var countPerZ: [Int: Int] = [:]

        for layer in mapData.layers ?? [] {
            let z = layer.z ?? 0
            let indexWithinZ = countPerZ[z] ?? 0
            countPerZ[z] = indexWithinZ + 1

            guard layer.chunked == true,
                  let chunkSize = layer.chunk_size, chunkSize > 0,
                  let gridW = layer.grid_w,
                  let gridH = layer.grid_h,
                  let template = layer.path_template
            else {
                // Non-chunked single-image layers are Phase 3; every shipping map is chunked.
                if layer.chunked != true {
                    Log.world("Skipping non-chunked layer (image: \(layer.image ?? "nil")) — not yet supported")
                }
                continue
            }

            layers.append(ChunkedLayer(z: z,
                                       indexWithinZ: indexWithinZ,
                                       alpha: Float(layer.alpha ?? 1),
                                       chunkSize: chunkSize,
                                       gridW: gridW,
                                       gridH: gridH,
                                       pathTemplate: template))
        }

        layers.sort { ($0.z, $0.indexWithinZ) < ($1.z, $1.indexWithinZ) }
        depths = Array(Set(layers.map(\.z))).sorted()

        Log.world("Map '\(mapData.name ?? "?")' loaded: \(layers.count) chunked layer(s), \(mapWidth)x\(mapHeight)")
    }

    /// Chunk tiles intersecting the camera frustum, in draw order.
    func visibleChunks(camera: Camera) -> [ChunkDraw] {
        guard mapWidth > 0, mapHeight > 0, !layers.isEmpty else { return [] }

        let halfMapW = mapWidth / 2
        let halfMapH = mapHeight / 2

        // Project the four screen corners onto the ground plane.
        var cameraLeft = Double.infinity
        var cameraRight = -Double.infinity
        var cameraTop = Double.infinity
        var cameraBottom = -Double.infinity

        let corners: [SIMD2<Float>] = [
            SIMD2(-1, 1), SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, -1),
        ]

        for ndc in corners {
            if let hit = camera.unprojectToGroundPlane(ndc: ndc) {
                let renderX = Double(hit.x)
                // Render space is Y-negated; convert back to world Y.
                let worldY = Double(-hit.y)
                cameraLeft = min(cameraLeft, renderX)
                cameraRight = max(cameraRight, renderX)
                cameraTop = min(cameraTop, worldY)
                cameraBottom = max(cameraBottom, worldY)
            } else {
                // Ray points above the horizon — stretch bounds to the map edge.
                if ndc.y > 0 { cameraTop = -halfMapH }
                if ndc.y < 0 { cameraBottom = halfMapH }
                if ndc.x < 0 { cameraLeft = -halfMapW }
                if ndc.x > 0 { cameraRight = halfMapW }
            }
        }

        if cameraLeft == .infinity { cameraLeft = -halfMapW }
        if cameraRight == -.infinity { cameraRight = halfMapW }
        if cameraTop == .infinity { cameraTop = -halfMapH }
        if cameraBottom == -.infinity { cameraBottom = halfMapH }

        var draws: [ChunkDraw] = []

        for layer in layers {
            // Pad generously so foreground tiles do not pop out at the screen edge.
            let layerBuffer = layer.chunkSize + 256

            let minXMap = max(-halfMapW, cameraLeft - layerBuffer)
            let maxXMap = min(halfMapW, cameraRight + layerBuffer)
            let minYMap = max(-halfMapH, cameraTop - layerBuffer)
            let maxYMap = min(halfMapH, cameraBottom + layerBuffer)

            if minXMap > maxXMap || minYMap > maxYMap { continue }

            let startCol = max(0, Int((minXMap + halfMapW) / layer.chunkSize))
            let endCol = min(layer.gridW - 1, Int((maxXMap + halfMapW) / layer.chunkSize))
            let startRow = max(0, Int((minYMap + halfMapH) / layer.chunkSize))
            let endRow = min(layer.gridH - 1, Int((maxYMap + halfMapH) / layer.chunkSize))

            if startCol > endCol || startRow > endRow { continue }

            let layerZ = Float(layer.z) + Float(layer.indexWithinZ) * 0.1
            let isOverlay = layer.z > 0

            for row in startRow...endRow {
                for col in startCol...endCol {
                    let path = layer.pathTemplate
                        .replacingOccurrences(of: "{x}", with: String(col))
                        .replacingOccurrences(of: "{y}", with: String(row))

                    let drawX = -halfMapW + Double(col) * layer.chunkSize
                    let drawY = -halfMapH + Double(row) * layer.chunkSize

                    draws.append(ChunkDraw(
                        path: path,
                        centerX: Float(drawX + layer.chunkSize / 2),
                        centerY: Float(-(drawY + layer.chunkSize / 2)),
                        z: layerZ,
                        size: Float(layer.chunkSize),
                        alpha: layer.alpha,
                        isOverlay: isOverlay
                    ))
                }
            }
        }

        return draws
    }
}
