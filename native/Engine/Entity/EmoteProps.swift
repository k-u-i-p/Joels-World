import simd

/// Every distinct geometry the emote table instantiates (`emotes.js`).
///
/// The JS builds these inline with three.js constructors and caches them on the rig; here they
/// are named up front so `CharacterRenderer` can upload one GPU mesh per case and reuse it for
/// every character. The comment on each case is the exact constructor it replaces, including
/// any geometry-space rotation or scale baked in at build time.
enum PropMesh: CaseIterable {
    case laserBeam      // CylinderGeometry(0.5, 0.5, 300, 8).rotateZ(π/2)
    case waterDrop      // SphereGeometry(1.5, 6, 6)
    case footprint      // CircleGeometry(6, 16)
    case apple          // SphereGeometry(3.5, 10, 10)
    case appleStem      // CylinderGeometry(0.3, 0.3, 3, 5)
    case crumb          // BoxGeometry(1.5, 1.5, 1.5)
    case plate          // CylinderGeometry(8, 6, 1, 16).rotateX(π/2)
    case steak          // CylinderGeometry(4, 4, 1.2, 8).rotateX(π/2)
    case cutlery        // BoxGeometry(0.5, 6, 2)
    case book           // BoxGeometry(18, 14, 0.5)
    case pen            // CylinderGeometry(0.5, 0.5, 6, 6)
    case dust           // SphereGeometry(4, 6, 6)
    case note           // BoxGeometry(3, 3, 3)
    case gasCloud       // SphereGeometry(8, 8, 8)
    case tearLarge      // SphereGeometry(2, 6, 6)
    case tearSmall      // SphereGeometry(1.5, 4, 4)
    case tennisBall     // SphereGeometry(2, 20, 20)
    case rugbyBall      // SphereGeometry(3.5, 12, 12).scale(1.5, 1, 1)
    case ripple         // TorusGeometry(5, 0.5, 4, 16).rotateX(π/2)
    case zBarFlat       // BoxGeometry(4, 1, 1)   — the top and bottom of a 'Z'
    case zBarDiagonal   // BoxGeometry(1, 4, 1)   — its middle stroke
    case heart          // Sprite with a canvas-rendered ❤️ texture

    /// Sprites are billboards: three.js replaces their world rotation with the camera's, so
    /// they always face the viewer.
    var isSprite: Bool { self == .heart }
}

/// Which node in the rig hierarchy a prop hangs off. The JS picks one per prop, and the choice
/// matters — `.head` inherits the head group's 0.65/0.65/0.7 scale, `.meshGroup` inherits the
/// character's yaw but not the body pivot's pitch, and `.world` is unparented entirely so
/// dropped footprints stay where they fell.
enum PropAnchor {
    /// `rig.head` — the head group, *including* its non-uniform scale.
    case head
    /// `rig.lHand` / `rig.rHand` — the hand sphere, which tracks the IK target and the
    /// forearm's orientation, so a held prop is only placed once the IK has resolved.
    case leftHand, rightHand
    /// `rig.bodyPivot` — moves with the emote's body translation and pitch.
    case bodyPivot
    /// `rig.emotePropsDirectional` and `rig.meshGroup` are the same transform: the character's
    /// position, heading and scale, with no body-pivot offset.
    case meshGroup
    /// The scene root. Only `wet` uses it, so its footprints stay behind on the floor.
    case world
}

/// One prop instance to draw this frame.
///
/// `local` is the prop's transform *within* its anchor; `CharacterRig` composes the world
/// matrix once the rest of the pose is settled, because several anchors (the hands especially)
/// are not known until the IK has run.
struct PropDraw {
    var mesh: PropMesh
    var anchor: PropAnchor
    var local: Float4x4

    /// Linear RGB, already through `parseHexColor`.
    var color: SIMD3<Float>
    var opacity: Float = 1

    /// `MeshBasicMaterial` in the JS — no lighting, no shadow term.
    var unlit: Bool = false
    /// `transparent: true`, which puts the prop in the blended pass behind the opaque rig.
    var transparent: Bool = false

    var roughness: Float = 1
    var metalness: Float = 0

    /// Set for sprites: the uniform scale to apply after the camera-facing basis.
    var billboardScale: Float?

    /// Filled in by `CharacterRig` before the pose is handed to the renderer.
    var worldTransform = matrix_identity_float4x4
}

/// A footprint `wet` has dropped on the floor. Unlike every other prop these persist across
/// frames — the JS keeps a pool of 16 meshes in the scene and rewrites the oldest in place.
struct Footprint {
    var x: Float = 0
    var y: Float = 0
    var rotation: Float = 0
    var scale: Float = 1
    var visible = false
    /// Milliseconds since the emote started, as `userData.lastDrop` records it.
    var lastDrop: Double = 0
}

/// Per-character rig state that has to survive between frames.
///
/// three.js keeps this implicitly on the `Object3D`s: `bodyPivot.position` holds whatever the
/// last emote assigned until something overwrites it, and the dance notes' rotation is
/// accumulated (`note.rotation.x += 0.1`) rather than derived from the clock. Reproducing the
/// pose exactly means keeping the same values around.
final class RigRuntime {
    /// `bodyPivot.position`, reset to standing height whenever the emote changes. It was a
    /// literal 15.5 in both places; `bodyPivotHeight` is derived from the leg and shoe now, so a
    /// copy of the old number here would have sunk every emoting character into the floor.
    var bodyPivotPosition = SIMD3<Float>(0, 0, CharacterRig.bodyPivotHeight)
    /// `bodyPivot.rotation` as an XYZ Euler.
    var bodyPivotRotation = SIMD3<Float>(0, 0, 0)
    /// `rig.head.rotation` — only `swim` touches it.
    var headRotation = SIMD3<Float>(0, 0, 0)

    /// The emote whose props are currently parented to the rig, so a change can tear them down.
    var currentEmoteName: String?

    /// `wet`'s footprint pool.
    var footprints: [Footprint] = []
    /// The dance notes' accumulated tumble, in radians.
    var noteSpin: [SIMD2<Float>] = []

    /// Called when `currentEmoteName` changes: the JS removes `emoteProps` and `crumbProps`
    /// from the scene and puts the body pivot back where it started.
    func resetForEmoteChange(to name: String?) {
        bodyPivotPosition = SIMD3(0, 0, CharacterRig.bodyPivotHeight)
        bodyPivotRotation = .zero
        headRotation = .zero
        footprints.removeAll()
        noteSpin.removeAll()
        currentEmoteName = name
    }
}
