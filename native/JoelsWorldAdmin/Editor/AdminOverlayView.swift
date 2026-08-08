import AppKit
import simd

/// The 2D layer over the Metal view. Port of `adminDraw` (`admin.js:1311-1464`), which draws
/// the same overlay onto `#uiCanvas` above the WebGL canvas.
///
/// Everything is projected through the live camera rather than drawn in a 2D map space, so
/// boxes sit on the ground plane in perspective exactly as the objects they describe do.
final class AdminOverlayView: NSView {
    /// The frame's world snapshot, pushed by the controller before each redraw.
    struct Snapshot {
        var camera: Camera
        var objects: [WorldObject] = []
        var npcs: [GameCharacter] = []
        var selection = EditorSelection()
        /// Where each NPC's roam circle is centred — its authored origin, not where it has
        /// wandered to. `admin.js` reads `_startX` off the character proxy for this.
        var roamOrigins: [Int: (x: Double, y: Double)] = [:]
        /// The selected NPC's patrol route, already resolved from cumulative offsets into
        /// world positions, and closed back to where it starts.
        var waypointRoute: [(x: Double, y: Double)] = []
        var backgroundImage: NSImage?
        var backgroundOrigin: (x: Double, y: Double) = (0, 0)
    }

    var snapshot = Snapshot(camera: Camera()) {
        didSet { needsDisplay = true }
    }

    /// Screen coordinates run Y-down here, matching the canvas the JS draws into and the
    /// output of `Camera.project`.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        guard viewport.x > 0, viewport.y > 0 else { return }

        let camera = snapshot.camera
        func screenPoint(_ worldX: Double, _ worldY: Double, _ z: Double) -> CGPoint {
            let projected = camera.project(worldX: worldX, worldY: worldY, z: z, viewport: viewport)
            return CGPoint(x: CGFloat(projected.screen.x), y: CGFloat(projected.screen.y))
        }

        drawBackgroundImage(in: ctx, screenPoint: screenPoint)

        for object in snapshot.objects {
            draw(object: object, in: ctx, screenPoint: screenPoint)
        }

        drawWaypointRoute(in: ctx, screenPoint: screenPoint)

        for npc in snapshot.npcs where snapshot.selection.npcId == npc.id {
            draw(npc: npc, in: ctx, screenPoint: screenPoint)
        }
    }

    // MARK: - Pieces

    /// A dropped PNG/JPG, used as a tracing reference while laying out a map.
    ///
    /// **Deliberate deviation from `admin.js`.** The JS drags the image by a *world*-space
    /// delta but draws it at those coordinates in *screen* space, so it is pinned to the
    /// window and slides out of alignment the moment the map is panned or zoomed. Here the
    /// origin is a world position and the image is projected like everything else, which is
    /// what a tracing reference has to do to be usable.
    private func drawBackgroundImage(in ctx: CGContext, screenPoint: (Double, Double, Double) -> CGPoint) {
        guard let image = snapshot.backgroundImage else { return }
        let origin = snapshot.backgroundOrigin
        let topLeft = screenPoint(origin.x, origin.y, 0)
        let bottomRight = screenPoint(origin.x + Double(image.size.width),
                                      origin.y + Double(image.size.height), 0)

        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)
        guard rect.width > 0, rect.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        ctx.saveGState()
        // The context is flipped; un-flip around the destination rect so the image is not
        // drawn upside down.
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// The selected NPC's patrol route.
    ///
    /// Not a port — neither `admin.js` nor anything else drew this. It visualises the roam
    /// circle but not the route, which is the harder of the two to author blind: waypoints are
    /// *cumulative offsets* from wherever the NPC starts, so reading a list of them tells you
    /// very little about where the NPC actually ends up.
    ///
    /// The dashed leg back to the start is the implicit `waypoints.count + 1` step that
    /// `NPCBehaviour.patrol` walks, which is not in the authored list either.
    private func drawWaypointRoute(in ctx: CGContext,
                                   screenPoint: (Double, Double, Double) -> CGPoint) {
        let route = snapshot.waypointRoute
        guard route.count > 1 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let points = route.map { screenPoint($0.x, $0.y, 0) }
        let amber = NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 0.95).cgColor

        ctx.setStrokeColor(amber)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 6])
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()

        // A step that only rotates lands on the previous point, so the markers stack up. That
        // is honest — the NPC does stand still for that step.
        ctx.setLineDash(phase: 0, lengths: [])
        for (index, point) in points.enumerated() {
            // The closing leg returns to the start marker; do not draw a second one over it.
            if index == points.count - 1, index > 0 { break }

            let radius: CGFloat = index == 0 ? 7 : 5
            ctx.setFillColor(index == 0 ? amber : NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.9).cgColor)
            ctx.setStrokeColor(amber)
            ctx.setLineWidth(2)
            ctx.addArc(center: point, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.drawPath(using: .fillStroke)

            guard index > 0 else { continue }
            let label = "\(index)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                       withAttributes: attributes)
        }
    }

    private func draw(object: WorldObject,
                      in ctx: CGContext,
                      screenPoint: (Double, Double, Double) -> CGPoint) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let isSelected = snapshot.selection.hasObject(object.id)
        ctx.setFillColor(fillColor(for: object, isSelected: isSelected))

        let angle = (object.rotation ?? 0) * .pi / 180
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        let halfWidth = (object.width ?? 0) / 2
        let halfLength = (object.length ?? 0) / 2
        let elevation = object.z ?? 0

        if object.shape == "circle" {
            let radius = max(object.width ?? 0, object.length ?? 0) / 2
            let centre = screenPoint(object.x, object.y, elevation)
            let edge = screenPoint(object.x + radius, object.y, elevation)
            let screenRadius = hypot(edge.x - centre.x, edge.y - centre.y)
            ctx.addArc(center: centre, radius: screenRadius,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
        } else {
            // The four corners are rotated in world space and projected individually, so the
            // quad keeps its perspective rather than being an axis-aligned screen rect.
            let corners = [(-halfWidth, -halfLength), (halfWidth, -halfLength),
                           (halfWidth, halfLength), (-halfWidth, halfLength)]
                .map { corner -> CGPoint in
                    screenPoint(object.x + corner.0 * cosAngle - corner.1 * sinAngle,
                                object.y + corner.0 * sinAngle + corner.1 * cosAngle,
                                elevation)
                }
            ctx.move(to: corners[0])
            for corner in corners.dropFirst() { ctx.addLine(to: corner) }
            ctx.closePath()
        }
        ctx.fillPath()

        guard isSelected, snapshot.selection.objectIds.first == object.id else { return }

        let handle = EditorGeometry.handleOffset(for: object)
        let handlePoint: CGPoint
        if object.shape == "circle" {
            handlePoint = screenPoint(object.x + handle.x, object.y + handle.y, elevation)
        } else {
            handlePoint = screenPoint(object.x + handle.x * cosAngle - handle.y * sinAngle,
                                      object.y + handle.x * sinAngle + handle.y * cosAngle,
                                      elevation)
        }

        // A flat 10 px screen square, so the grab target does not shrink with distance.
        let size: CGFloat = 10
        let rect = CGRect(x: handlePoint.x - size / 2, y: handlePoint.y - size / 2,
                          width: size, height: size)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(2)
        ctx.addRect(rect)
        ctx.drawPath(using: .fillStroke)
    }

    /// `admin.js:1343-1353`: selected wins, then walk-through green, then named red versus
    /// unnamed purple — and a 3D model overrides all of them with sky blue.
    private func fillColor(for object: WorldObject, isSelected: Bool) -> CGColor {
        if object.shape == "3d_model" {
            return NSColor(red: 0, green: 191 / 255, blue: 1, alpha: 0.6).cgColor
        }
        if isSelected {
            return NSColor(red: 0.5, green: 0, blue: 0.5, alpha: 0.5).cgColor
        }
        if object.noclip == true || object.clip == -1 {
            return NSColor(red: 0, green: 1, blue: 0, alpha: 0.5).cgColor
        }
        return object.name != nil
            ? NSColor(red: 1, green: 0, blue: 0, alpha: 0.5).cgColor
            : NSColor(red: 155 / 255, green: 89 / 255, blue: 182 / 255, alpha: 0.5).cgColor
    }

    /// Three rings on the selected NPC: its hitbox, its roam radius, and its interaction radius.
    private func draw(npc: GameCharacter,
                      in ctx: CGContext,
                      screenPoint: (Double, Double, Double) -> CGPoint) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let elevation = 0.0
        let centre = screenPoint(npc.x, npc.y, elevation)

        func screenRadius(from originX: Double, originY: Double, centre: CGPoint, radius: Double) -> CGFloat {
            let edge = screenPoint(originX + radius, originY, elevation)
            return hypot(edge.x - centre.x, edge.y - centre.y)
        }

        let size = max(npc.width ?? 0, npc.height ?? 0) / 2
        let hitRadius = (size > 0 ? size : 20) + 5
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(3)
        ctx.setStrokeColor(NSColor.cyan.cgColor)
        ctx.addArc(center: centre,
                   radius: screenRadius(from: npc.x, originY: npc.y, centre: centre, radius: hitRadius),
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        if let roamRadius = npc.roam_radius, roamRadius > 0 {
            let origin = snapshot.roamOrigins[npc.id] ?? (npc.x, npc.y)
            let roamCentre = screenPoint(origin.x, origin.y, elevation)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(NSColor(red: 1, green: 0, blue: 0, alpha: 0.7).cgColor)
            ctx.setLineDash(phase: 0, lengths: [10, 10])
            ctx.addArc(center: roamCentre,
                       radius: screenRadius(from: origin.x, originY: origin.y,
                                            centre: roamCentre, radius: roamRadius),
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }

        let interactionRadius = npc.interaction_radius ?? 150
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(red: 0, green: 0, blue: 1, alpha: 0.8).cgColor)
        ctx.setLineDash(phase: 0, lengths: [5, 5])
        ctx.addArc(center: centre,
                   radius: screenRadius(from: npc.x, originY: npc.y,
                                        centre: centre, radius: interactionRadius),
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
    }
}
