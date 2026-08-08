import Foundation
import simd

/// A map whose `import` field names a script instead of describing a world (`maps.json` id 4,
/// Tennis). `main.js:721-734` clears the game loop and hands the frame over to that module;
/// this is the same handover.
protocol Minigame: AnyObject {
    /// False when the game draws itself rather than being drawn by the Metal renderer. The
    /// original 2D tennis is a canvas game in the web build and stays one here; `Tennis3DGame`
    /// is not, and returns true.
    var usesWorldRenderer: Bool { get }

    func start()
    /// One frame of simulation. `dt` is already clamped to 100 ms, as `gameloop.js:83` does.
    func update(dt: Double)
    func stop()
}

/// A minigame drawn by the real renderer, with the real character rigs.
///
/// The overworld's own drawing pipeline is a map of chunked ground tiles plus a roster of
/// networked characters, and a minigame has neither. So instead of pretending to be a map, one
/// of these hands the renderer three things a frame: the characters to pose, the solid shapes
/// to draw, and where to put the camera. Everything else — lighting, shadows, SSAO, the rig,
/// the clip mask — it gets for free.
protocol WorldRenderedMinigame: Minigame {
    /// Characters to pose and draw this frame, in draw order.
    var sceneCharacters: [MinigameCharacter] { get }

    /// The solid geometry: the court, its lines, the net, the ball. Rebuilt every frame, which
    /// costs nothing at this scale and means the ball is just another entry.
    var scenePrimitives: [ScenePrimitive] { get }

    /// Authored `.glb` models to stand in the scene — the stadium the court sits inside.
    /// Static, so this is read once when the minigame starts rather than every frame.
    var sceneModels: [SceneModel] { get }

    /// Where the camera goes. Called after `update(dt:)` with the same step, in place of the
    /// overworld's follow-the-player logic. It takes `dt` because a camera that eases towards
    /// its target has to ease in *seconds* — a fixed fraction per frame runs at half speed on a
    /// 120 Hz display and twice as fast on a dropped one.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double)

    /// Clear colour behind the scene, as a CSS hex string. Nil keeps the map's own.
    var backgroundColor: String? { get }
}

extension WorldRenderedMinigame {
    var usesWorldRenderer: Bool { true }
    var backgroundColor: String? { nil }
    var sceneModels: [SceneModel] { [] }
}

/// One authored `.glb` standing in a minigame's scene, in **render space** (Y negated, Z up).
///
/// The overworld gets its models from `WorldObject`s the server sends; a minigame has no server
/// objects and no map, so it names them itself. `PropRenderer` draws both from the same list —
/// the only thing this carries that a placed object does not is the choice below.
struct SceneModel {
    /// Relative to the asset root, e.g. `models/tennis_stadium.glb`.
    var path: String
    /// glTF is authored Y-up and this world is Z-up, so a placement almost always ends in
    /// `Float4x4.rotationX(.pi / 2)`, the same way `PropRenderer.transform(for:)` does.
    var transform: Float4x4
    /// **Off by default, and that is the interesting one.** The shadow map is a 1024² depth
    /// buffer over a 3000-unit cone: a 550,000-vertex stadium drawn into it costs a second full
    /// pass over the model and buys a shadow of a grandstand onto seats that are already
    /// occluded in their own base colour. A prop small enough to shadow something the player
    /// looks at should say so.
    var castsShadow: Bool = false
}

/// One character a minigame wants drawn, with everything the rig needs that a bare
/// `GameCharacter` cannot carry.
struct MinigameCharacter {
    var character: GameCharacter
    /// How the legs are moving — including sideways. See `Gait`.
    var gait: Gait = .still
    /// A final pass over the pose, for aiming a racket arm at a ball.
    var poseOverride: RigOverride?
}

/// A solid shape for the renderer to draw, already in **render space** (Y negated, Z up).
///
/// The shapes are deliberately a closed set of primitives rather than arbitrary meshes: the
/// renderer caches one GPU mesh per distinct `Shape`, and a court is a few dozen boxes that
/// resolve to a handful of distinct sizes. Sizes live in the mesh rather than in a scale on the
/// transform because `Shaders.metal` transforms normals by the model matrix directly, not by
/// its inverse transpose — a non-uniform scale there would light the geometry wrongly.
struct ScenePrimitive {
    enum Shape: Hashable {
        case box(width: Float, height: Float, depth: Float)
        case sphere(radius: Float)
        /// Long axis along +Y before the transform, matching `MeshFactory`.
        case cylinder(radius: Float, height: Float)
        /// On the XY plane, facing +Z.
        case plane(width: Float, height: Float)
    }

    var shape: Shape
    var transform: Float4x4
    var color: SIMD3<Float>
    var opacity: Float = 1
    var roughness: Float = 0.9
    var metalness: Float = 0
    /// Flat-shaded, ignoring the lights. The court's painted lines use it so they read as
    /// crisp white from every camera angle, the way they do in the 2D original.
    var unlit: Bool = false
    /// Whether it goes into the shadow map. The ground plane and the painted lines do not —
    /// a flat plane casts nothing, and the lines would only shadow-acne the surface they sit on.
    var castsShadow: Bool = true
    /// Blended rather than opaque. Drawn after everything solid, without writing depth.
    var blended: Bool { opacity < 0.999 }
}

enum MinigameKind: String {
    /// The original 2D canvas game, kept playable for comparison.
    case tennis
    /// The rebuild: real engine, real rigs, real physics.
    case tennis3d

    /// `mapData.import` is a module URL — `/src/minigames/tennis3d.js`.
    init?(importPath: String) {
        let name = (importPath as NSString).lastPathComponent
        guard let kind = MinigameKind(rawValue: (name as NSString).deletingPathExtension) else {
            return nil
        }
        self = kind
    }
}

/// What a minigame needs from the app around it: the socket, the sound engine and the dialog.
protocol MinigameHost: AnyObject {
    func minigameShowDialog(_ text: String, onConfirm: @escaping () -> Void)
    func minigameChangeMap(_ mapId: Int)
    func minigameAwardBadge(_ badge: String)
    func minigamePlayBackground(path: String, volume: Double)
    /// `playPooled` followed by `setRate` — folded into one call so the `World` layer never
    /// holds an audio handle.
    func minigamePlayEffect(path: String, volume: Double, rate: Double)
    func minigameStopBackground()
}

extension MinigameHost {
    func minigamePlayEffect(path: String, volume: Double) {
        minigamePlayEffect(path: path, volume: volume, rate: 1)
    }
}
