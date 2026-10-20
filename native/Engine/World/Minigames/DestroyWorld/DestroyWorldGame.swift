import Foundation
import simd

/// **Destroy the World** — Joel's idea: *"you are on a moving train shooting with a
/// flamethrower … if you shoot fire it turns into ice and you can melt the ice … 3D out the
/// eyes with a low-poly style … make it say ULTIMATE COMBO."*
///
/// You stand on the roof of a train rolling through the countryside, looking out of your own
/// eyes, with a flamethrower. Everything you point it at goes through the same three steps:
///
/// 1. **Fire.** Flame something and it catches. Leave it burning and a tree falls over
///    (TIMBER!), a house falls in, a haystack goes up.
/// 2. **Ice.** Flame something that is *already on fire* and — Joel's rule — the fire turns to
///    ice. It freezes solid inside a block of ice. Campfires are already burning, so they go
///    straight to ice.
/// 3. **Melt.** Flame the ice and it melts into a puddle, and whatever was inside it falls down.
///
/// Every one of those scores, and doing them quickly one after another is a **combo**: COMBO,
/// SUPER COMBO, MEGA COMBO, and at twelve in a row, **ULTIMATE COMBO**. Destroy a hundred things
/// and you have destroyed the world.
///
/// It is built like School Rush: a `WorldRenderedMinigame` that hands the renderer a list of
/// boxes every frame. The train really moves (towards +Y), and the countryside is generated from
/// where it is. The first-person camera is School Escape's trick — see `updateCamera`.
///
/// Everything in here is in **metres, render space** (X right, Y along the track, Z up) until
/// `DestroyWorldKit.m()` turns it into world units for the renderer.
final class DestroyWorldGame: WorldRenderedMinigame {

    typealias Kit = DestroyWorldKit

    // MARK: - Tuning

    /// The numbers Joel is most likely to want to change.
    enum Tuning {
        /// How fast the train goes, in metres per second. 9 is about 20 mph — fast enough to feel
        /// like a train, slow enough to set a tree on fire, freeze it and melt it before it is gone.
        static let trainSpeed: Float = 9

        /// How fast a flame leaves the nozzle, how long it lives, and how many come out a second.
        static let flameSpeed: Float = 26
        static let flameLife: Float = 0.75
        static let flamesPerSecond: Float = 70

        /// How long a flame has to be on something to light it, to freeze it once it is
        /// burning, and to melt it once it is ice — in seconds of flaming it.
        static let heatToIgnite: Float = 0.2
        static let heatToFreeze: Float = 0.5
        static let heatToMelt: Float = 0.5
        /// Something you have just lit cannot freeze until it has burned for this long, so a
        /// quick blast lights things rather than lighting and freezing them in one go.
        static let burnBeforeFreezing: Float = 0.3

        /// How long something burns before it falls down on its own.
        static let burnTime: Float = 4.0
        /// How long a block of ice takes to melt.
        static let meltTime: Float = 1.2

        /// Points, before the combo multiplier.
        static let pointsIgnite = 10
        static let pointsFreeze = 50
        static let pointsMelt = 75
        static let pointsDestroy = 30

        /// How long you have to do the next thing before the combo runs out.
        static let comboWindow: Float = 2.8

        /// Destroy this many things and you have destroyed the world.
        static let worldSize = 100

        /// How far left and right of the track things stand. The flame reaches about 19 m.
        static let nearest: Float = 5
        static let furthest: Float = 19

        /// Caps, so a big fire cannot eat the frame.
        static let maxParticles = 420
        static let maxDebris = 90
    }

    // MARK: - Things in the world

    enum State: Equatable {
        case fresh
        case burning
        case frozen
        case melting
        /// Fallen over, fallen in, put out. Smoulders for a while and then just sits there.
        case destroyed
    }

    struct Thing {
        /// A number nothing else has, so something can keep track of one thing.
        var id: Int
        var kind: Kit.Kind
        var variant: Int
        /// Where it stands, in metres.
        var position: SIMD3<Float>
        var heading: Float
        var state: State = .fresh
        /// Seconds of flame it has taken in its current state.
        var heat: Float = 0
        var stateTime: Float = 0
        /// How black it has gone, 0 to 1.
        var char: Float = 0
        /// How much of the block of ice is left, 0 to 1.
        var ice: Float = 0
        var puddle: Float = 0

        /// The fall: a tree tips over about its base, faster and faster, and bounces when it lands.
        var falling = false
        var fallAngle: Float = 0
        var fallSpeed: Float = 0
        var fallDirection: Float = 0
        var landed = false

        /// How far a house or a haystack has sunk into the ground as it collapses.
        var sink: Float = 0
        var shake: Float = 0

        var emit: Float = 0
        var radius: Float { Kit.radius(of: kind, variant: variant) }
        var height: Float { Kit.height(of: kind, variant: variant) }
    }

    private(set) var things: [Thing] = []

    // MARK: - Particles

    enum ParticleKind {
        case flame
        case smoke
        case steam
        case chimney
    }

    private struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var age: Float = 0
        var life: Float
        var startSize: Float
        var endSize: Float
        var kind: ParticleKind
        /// Flames from your flamethrower ride along with the train and can set things alight.
        var fromNozzle = false
        var spin: SIMD2<Float>
    }

    private var particles: [Particle] = []

    /// Chunks that fly off a house when it falls in, or off a block of ice.
    private struct Debris {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var spin: SIMD3<Float>
        var age: Float = 0
        var big: Bool
        var color: SIMD3<Float>
    }

    private var debris: [Debris] = []

    // MARK: - You

    /// Where the back of the train is along the track, in metres. You stand here.
    private(set) var trainY: Float = 0
    private(set) var elapsed: Float = 0

    /// Which way you are looking, in radians. 0 is straight down the track; positive is left.
    private(set) var look: Float = 0
    /// How far below level you are aiming, in radians.
    private(set) var aimDown: Float = 0.2
    private(set) var firing = false

    /// Set by `updateCamera`: how far below level the middle of the screen is, and how tall
    /// half the screen is as a tangent. The HUD needs both to put the crosshair where the flame
    /// is going.
    private var screenCentreDown: Float = 0.12
    private var halfScreenTangent: Float = 0.4

    /// Where your eyes are this frame — the camera and the flamethrower both read it.
    private var eye = SIMD3<Float>(0, 0, Kit.eyeHeight)

    // MARK: - Score

    private(set) var score = 0
    private(set) var combo = 0
    private(set) var bestCombo = 0
    private var comboTimer: Float = 0
    private(set) var destroyedCount = 0
    private(set) var best: Int = DestroyWorldGame.storedBest
    private var worldDestroyedAnnounced = false
    private var toldAboutIce = false
    private var toldAboutMelting = false

    private static let bestKey = "destroyworld.best"
    private static var storedBest: Int { UserDefaults.standard.integer(forKey: bestKey) }

    /// How much of the world is gone, 0 to 1.
    var worldDestroyed: Double {
        min(1, Double(destroyedCount) / Double(Tuning.worldSize))
    }

    /// How much longer the combo has, 0 to 1, for the HUD's bar.
    var comboTimeLeft: Double { Double(max(0, comboTimer / Tuning.comboWindow)) }

    /// How much each point is worth right now.
    var multiplier: Int { min(10, 1 + combo / 3) }

    /// Where the flame is going on screen: how far below the middle, as a fraction of half the
    /// screen's height. Negative is above.
    var crosshairOffset: Double {
        Double(tan(aimDown - screenCentreDown) / max(0.01, halfScreenTangent))
    }

    // MARK: - What the HUD shows

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
        /// True for the big rainbow COMBO banners.
        var isCombo: Bool
        /// Goes up every time, so the HUD knows to replay its pop.
        var serial: Int
    }

    private(set) var announcement: Announcement?
    private var announcementSerial = 0

    /// The little "+50 FROZEN!" pop-ups. The HUD takes them away each frame.
    struct Popup {
        enum Style { case fire, ice, melt, destroy, info }
        var text: String
        var style: Style
    }

    private var pendingPopups: [Popup] = []

    func takePopups() -> [Popup] {
        defer { pendingPopups.removeAll() }
        return pendingPopups
    }

    var onPresentationChanged: (() -> Void)?

    unowned let host: MinigameHost
    private var active = false

    private var random = DeterministicRandom(seed: 0xD35_7804)
    /// How far along the track things have been placed.
    private var spawnedTo: Float = 0
    private var chimneyEmit: Float = 0
    private var nextThingId = 0
    private var nozzleEmit: Float = 0

    // MARK: - Lifecycle

    init(host: MinigameHost) {
        self.host = host
    }

    func start() {
        active = true
        Log.world("[DestroyWorld] All aboard — destroy \(Tuning.worldSize) things to destroy the world")
        beginRun()
        host.minigamePlayBackground(path: "/media/chase_music.mp3", volume: 0.22)
    }

    private func beginRun() {
        things.removeAll()
        particles.removeAll()
        debris.removeAll()
        trainY = 0
        elapsed = 0
        look = 0
        aimDown = 0.2
        firing = false
        score = 0
        combo = 0
        bestCombo = 0
        comboTimer = 0
        destroyedCount = 0
        worldDestroyedAnnounced = false
        toldAboutIce = false
        toldAboutMelting = false
        best = Self.storedBest
        spawnedTo = 18
        random.reseed(0xD35_7804 &+ UInt64(Date().timeIntervalSince1970))

        announce("DESTROY THE WORLD", subtitle: "Hold FIRE · drag to aim", duration: 3.2)
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.25, rate: 1.4)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        things.removeAll()
        particles.removeAll()
        debris.removeAll()
        host.minigameStopBackground()
    }

    func requestExit() {
        host.minigameShowDialog("Get off the train and stop destroying the world?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    func restart() {
        guard active else { return }
        saveBest()
        beginRun()
    }

    // MARK: - Input

    func setFiring(_ on: Bool) {
        guard active else { return }
        firing = on
    }

    /// A drag. `dx` turns your head, `dy` moves where you are aiming up and down — both in
    /// radians.
    func aim(dx: Double, dy: Double) {
        guard active else { return }
        look += Float(dx)
        // Keep it as one turn either way, so it does not grow for ever.
        if look > .pi { look -= 2 * .pi }
        if look < -.pi { look += 2 * .pi }
        aimDown = min(max(aimDown + Float(dy), -0.15), 0.62)
    }

    // MARK: - Frame

    func update(dt: Double) {
        guard active else { return }
        let dt = Float(min(dt, 0.05))
        elapsed += dt

        trainY += Tuning.trainSpeed * dt
        // Clickety-clack: a little sway and bounce, so it feels like a train and not a lift.
        eye = SIMD3(0.05 * sin(elapsed * 1.7),
                    trainY,
                    Kit.eyeHeight + 0.035 * abs(sin(elapsed * 8.5)))

        if comboTimer > 0 {
            comboTimer -= dt
            if comboTimer <= 0 { endCombo() }
        }

        if var current = announcement {
            current.remaining -= Double(dt)
            if current.remaining <= 0 {
                announcement = nil
            } else {
                announcement = current
            }
        }

        spawnAhead()
        emitFromNozzle(dt: dt)
        emitChimneySmoke(dt: dt)
        stepParticles(dt: dt)
        applyFlameHits(dt: dt)
        stepThings(dt: dt)
        stepDebris(dt: dt)
        pruneBehind()
    }

    // MARK: - Building the countryside

    /// Puts things beside the track, a few metres at a time, until there are enough in front.
    private func spawnAhead() {
        let horizon = trainY + 150
        let step: Float = 6.5
        while spawnedTo < horizon {
            for side: Float in [-1, 1] {
                spawnSlot(y: spawnedTo, side: side, length: step)
            }
            spawnedTo += step
        }
    }

    private func spawnSlot(y: Float, side: Float, length: Float) {
        let roll = random.float()
        let kind: Kit.Kind
        var count = 1
        switch roll {
        case ..<0.42:
            kind = random.float() < 0.6 ? .pine : .oak
            count = random.float() < 0.4 ? 2 : 1
        case ..<0.53: kind = .house
        case ..<0.65: kind = .hay
        case ..<0.72: kind = .campfire
        default: return
        }

        for _ in 0..<count {
            let variant = Int(random.float() * Float(Kit.variants)) % Kit.variants
            let radius = Kit.radius(of: kind, variant: variant)
            let nearest = max(Tuning.nearest, radius + 3)
            let furthest = kind == .house ? 15 : Tuning.furthest
            let across = nearest + random.float() * (furthest - nearest)
            let along = y + random.float() * length
            let position = SIMD3(side * across, along, 0)

            // Nothing standing inside anything else.
            let crowded = things.suffix(24).contains {
                simd_distance(SIMD2($0.position.x, $0.position.y), SIMD2(position.x, position.y))
                    < $0.radius + radius + 0.6
            }
            if crowded { continue }

            nextThingId += 1
            var thing = Thing(id: nextThingId, kind: kind, variant: variant, position: position,
                              heading: random.float() * 2 * .pi)
            // A house turns its front door to the track.
            if kind == .house { thing.heading = side > 0 ? 0 : .pi }
            // Campfires are already burning — that is what makes them fires.
            if kind == .campfire {
                thing.state = .burning
                thing.stateTime = Tuning.burnBeforeFreezing
            }
            things.append(thing)
        }
    }

    private func pruneBehind() {
        let cutoff = trainY - Kit.drawBehind + 5
        things.removeAll { $0.position.y < cutoff - 10 }
        particles.removeAll { $0.position.y < cutoff - 20 }
    }

    // MARK: - The flamethrower

    /// Which way the flame goes: where you are looking, tipped down by where you are aiming.
    private var aimDirection: SIMD3<Float> {
        let level = SIMD3<Float>(-sin(look), cos(look), 0)
        return simd_normalize(level * cos(aimDown) + SIMD3(0, 0, -sin(aimDown)))
    }

    private var rightDirection: SIMD3<Float> { SIMD3(cos(look), sin(look), 0) }

    /// Where the flames come out: the end of the barrel, low and to the right of your eyes.
    private var nozzle: SIMD3<Float> {
        let forward = aimDirection
        let up = simd_cross(rightDirection, forward)
        return eye + forward * 1.0 + rightDirection * 0.2 - up * 0.19
    }

    private func emitFromNozzle(dt: Float) {
        guard firing else {
            nozzleEmit = 0
            return
        }
        nozzleEmit += Tuning.flamesPerSecond * dt
        let forward = aimDirection
        let start = nozzle
        while nozzleEmit >= 1 {
            nozzleEmit -= 1
            let spread = SIMD3(random.spread(), random.spread(), random.spread()) * 2.2
            let speed = Tuning.flameSpeed * (0.85 + 0.3 * random.float())
            addParticle(Particle(position: start + forward * random.float() * 0.6,
                                 velocity: forward * speed + spread,
                                 life: Tuning.flameLife * (0.8 + 0.4 * random.float()),
                                 startSize: 0.2, endSize: 1.15,
                                 kind: .flame, fromNozzle: true,
                                 spin: SIMD2(random.spread() * 9, random.spread() * 9)))
        }
    }

    private func emitChimneySmoke(dt: Float) {
        chimneyEmit += 9 * dt
        while chimneyEmit >= 1 {
            chimneyEmit -= 1
            let start = SIMD3(0, trainY, 0) + Kit.chimneyOffset
            addParticle(Particle(position: start,
                                 velocity: SIMD3(random.spread() * 0.6, Tuning.trainSpeed * 0.3,
                                                 3.5 + random.float()),
                                 life: 2.6, startSize: 0.6, endSize: 2.6, kind: .chimney,
                                 spin: SIMD2(random.spread() * 2, random.spread() * 2)))
        }
    }

    private func addParticle(_ particle: Particle) {
        guard particles.count < Tuning.maxParticles else { return }
        particles.append(particle)
    }

    private func stepParticles(dt: Float) {
        let trainVelocity = SIMD3<Float>(0, Tuning.trainSpeed, 0)
        for index in particles.indices {
            particles[index].age += dt
            let kind = particles[index].kind
            switch kind {
            case .flame:
                // Your flames slow down as they go and drift upwards, which is what bends the
                // stream into a flame instead of a laser. They slow down relative to the train,
                // so the stream goes where you point it however fast you are going.
                particles[index].velocity *= exp(-1.7 * dt)
                particles[index].velocity.z += 4 * dt
            case .smoke, .chimney:
                particles[index].velocity *= exp(-0.6 * dt)
                particles[index].velocity.z += 0.8 * dt
            case .steam:
                particles[index].velocity *= exp(-1.2 * dt)
                particles[index].velocity.z += 2 * dt
            }
            var move = particles[index].velocity
            if particles[index].fromNozzle { move += trainVelocity }
            particles[index].position += move * dt
            if particles[index].position.z < 0.1 {
                particles[index].position.z = 0.1
                particles[index].velocity.z = abs(particles[index].velocity.z) * 0.3
            }
        }
        particles.removeAll { $0.age >= $0.life }
    }

    /// Counts the flames touching each thing and turns that into heat. The flames are the hit
    /// test, so what you see burning is exactly what is burning.
    private func applyFlameHits(dt: Float) {
        guard particles.contains(where: { $0.fromNozzle }) else { return }

        var touching = [Int](repeating: 0, count: things.count)
        var fizzled: [Int] = []
        for (number, particle) in particles.enumerated()
        where particle.fromNozzle && particle.age > 0.03 {
            for index in things.indices {
                let thing = things[index]
                guard thing.state != .destroyed else { continue }
                let reach = thing.radius + 0.7
                let dx = particle.position.x - thing.position.x
                let dy = particle.position.y - thing.position.y
                guard dx * dx + dy * dy < reach * reach,
                      particle.position.z < thing.height + 0.6 else { continue }
                // **Flame on ice fizzles.** It goes out in a puff of steam at the surface of the
                // ice instead of carrying on through it — which is what lets you actually *see*
                // the block of ice while you melt it, rather than a ball of fire where it is.
                if thing.state == .frozen || thing.state == .melting {
                    fizzled.append(number)
                }
                if thing.state != .melting { touching[index] += 1 }
                break
            }
        }
        if !fizzled.isEmpty {
            for number in fizzled where random.float() < 0.3 {
                steam(at: particles[number].position)
            }
            for number in fizzled.reversed() { particles.remove(at: number) }
        }

        for index in things.indices where touching[index] > 0 {
            // Three flames at once is a direct hit; fewer is a glancing one.
            let heat = dt * min(1, Float(touching[index]) / 3)
            heatUp(index, by: heat)
        }
    }

    private func heatUp(_ index: Int, by heat: Float) {
        switch things[index].state {
        case .fresh:
            things[index].heat += heat
            if things[index].heat >= Tuning.heatToIgnite { ignite(index) }
        case .burning:
            guard things[index].stateTime >= Tuning.burnBeforeFreezing else { return }
            things[index].heat += heat
            if things[index].heat >= Tuning.heatToFreeze { freeze(index) }
        case .frozen:
            guard things[index].ice >= 0.99 else { return }
            things[index].heat += heat
            if things[index].heat >= Tuning.heatToMelt { startMelting(index) }
        case .melting, .destroyed:
            break
        }
    }

    // MARK: - Fire, ice, melt

    private func setState(_ index: Int, _ state: State) {
        things[index].state = state
        things[index].stateTime = 0
        things[index].heat = 0
    }

    private func ignite(_ index: Int) {
        setState(index, .burning)
        award(Tuning.pointsIgnite, "BURN!", style: .fire)
        host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: 0.25, rate: 0.55)
    }

    /// **Joel's rule: shoot fire and it turns into ice.**
    private func freeze(_ index: Int) {
        setState(index, .frozen)
        things[index].ice = 0.25
        award(Tuning.pointsFreeze, "FROZEN!", style: .ice)
        host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.35, rate: 2.6)
        burst(at: things[index].position + SIMD3(0, 0, things[index].height * 0.5),
              count: 6, color: Kit.iceTint, speed: 6)
        if !toldAboutIce {
            toldAboutIce = true
            announce("FIRE + FIRE = ICE!", subtitle: "Now flame the ice to melt it", duration: 2.6)
        }
    }

    private func startMelting(_ index: Int) {
        setState(index, .melting)
        award(Tuning.pointsMelt, "MELTED!", style: .melt)
        host.minigamePlayEffect(path: "/media/splash.mp3", volume: 0.35, rate: 1.2)
        if !toldAboutMelting {
            toldAboutMelting = true
            if announcement?.isCombo != true {
                announce("IT'S MELTING!", subtitle: "Fire, then ice, then melt = big points",
                         duration: 2.0)
            }
        }
    }

    /// The end of everything: it falls over, falls in, or goes out.
    private func destroy(_ index: Int) {
        let wasFrozen = things[index].state == .melting
        setState(index, .destroyed)
        destroyedCount += 1

        let thing = things[index]
        switch thing.kind {
        case .pine, .oak:
            // Away from the track, roughly — a tree falling on the train would be a different game.
            let away: Float = thing.position.x > 0 ? 0 : .pi
            things[index].fallDirection = away + random.spread() * 0.7
            things[index].falling = true
            things[index].fallAngle = 0.04
            things[index].fallSpeed = 0.35
            award(Tuning.pointsDestroy, "TIMBER!", style: .destroy)
        case .house:
            award(Tuning.pointsDestroy * 2, "KABOOM!", style: .destroy)
            burst(at: thing.position + SIMD3(0, 0, 3), count: 14,
                  color: wasFrozen ? Kit.iceTint : Kit.hex("#c0392b"), speed: 9)
            host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.5, rate: 0.4)
        case .hay:
            award(Tuning.pointsDestroy, "POOF!", style: .destroy)
            burst(at: thing.position + SIMD3(0, 0, 1.4), count: 10,
                  color: Kit.hex("#e7c45a"), speed: 7)
        case .campfire:
            award(Tuning.pointsDestroy, "PUT OUT!", style: .destroy)
            for _ in 0..<8 { steam(at: thing.position + SIMD3(0, 0, 0.6)) }
        }

        if destroyedCount == Tuning.worldSize, !worldDestroyedAnnounced {
            worldDestroyedAnnounced = true
            announce("YOU DESTROYED THE WORLD!!!", subtitle: "...there's more world. Keep going!",
                     duration: 4, isCombo: true)
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.55)
        }
        onPresentationChanged?()
    }

    private func stepThings(dt: Float) {
        for index in things.indices {
            things[index].stateTime += dt
            let thing = things[index]

            switch thing.state {
            case .fresh:
                // Heat that is not kept up fades, so a flame that only brushed a tree does not
                // count towards lighting it a minute later.
                things[index].heat = max(0, thing.heat - dt * 0.4)

            case .burning:
                if thing.kind != .campfire {
                    things[index].char = min(1, thing.char + dt / (Tuning.burnTime * 0.8))
                }
                emitFire(from: thing, dt: dt, index: index)
                if thing.kind != .campfire, thing.stateTime >= Tuning.burnTime {
                    destroy(index)
                }

            case .frozen:
                // It snaps into its block of ice rather than appearing in it.
                things[index].ice = min(1, thing.ice + dt * 6)

            case .melting:
                let melted = min(1, thing.stateTime / Tuning.meltTime)
                things[index].ice = 1 - melted
                things[index].puddle = melted
                if random.float() < dt * 14 {
                    steam(at: thing.position + SIMD3(random.spread() * thing.radius,
                                                     random.spread() * thing.radius,
                                                     random.float() * thing.height))
                }
                if melted >= 1 { destroy(index) }

            case .destroyed:
                stepCollapse(index, dt: dt)
                // A while of smoke from something that burned.
                if thing.char > 0.25, thing.stateTime < 6, random.float() < dt * 6 {
                    let top = thing.falling || thing.landed ? 0.8 : thing.height * 0.6
                    addParticle(Particle(
                        position: thing.position + SIMD3(random.spread() * thing.radius,
                                                         random.spread() * thing.radius, top),
                        velocity: SIMD3(random.spread() * 0.4, random.spread() * 0.4, 1.4),
                        life: 2.2, startSize: 0.5, endSize: 2.2, kind: .smoke,
                        spin: SIMD2(random.spread() * 2, random.spread() * 2)))
                }
            }
        }
    }

    /// The tree falling over, the house falling in.
    private func stepCollapse(_ index: Int, dt: Float) {
        let thing = things[index]
        switch thing.kind {
        case .pine, .oak:
            guard thing.falling else { return }
            // A falling tree speeds up the further over it goes — the same sum as a pendulum
            // upside down. 7 makes it a satisfying second and a bit.
            things[index].fallSpeed += 7 * sin(max(thing.fallAngle, 0.05)) * dt
            things[index].fallAngle += things[index].fallSpeed * dt
            let flat: Float = 1.48
            if things[index].fallAngle >= flat {
                things[index].fallAngle = flat
                if things[index].fallSpeed > 0.8 {
                    if !thing.landed {
                        things[index].landed = true
                        host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.45,
                                                rate: 0.38)
                        let reach = thing.height * 0.75
                        let tip = thing.position + SIMD3(cos(thing.fallDirection) * reach,
                                                         sin(thing.fallDirection) * reach, 0.5)
                        burst(at: tip, count: 6, color: thing.char > 0.5 ? Kit.charcoal
                                                                          : Kit.hex("#3b9447"),
                              speed: 5)
                    }
                    // A little bounce.
                    things[index].fallSpeed = -things[index].fallSpeed * 0.22
                } else {
                    things[index].fallSpeed = 0
                    things[index].falling = false
                }
            }
        case .house, .hay:
            let deepest = thing.height * 0.82
            guard thing.sink < deepest else {
                things[index].shake = 0
                return
            }
            things[index].sink = min(deepest, thing.sink + dt * (thing.kind == .house ? 2.4 : 2.0))
            things[index].shake = 0.09 * sin(elapsed * 60)
            if random.float() < dt * 10 {
                addParticle(Particle(
                    position: thing.position + SIMD3(random.spread() * thing.radius,
                                                     random.spread() * thing.radius, 0.5),
                    velocity: SIMD3(random.spread() * 2, random.spread() * 2, 1.5),
                    life: 1.6, startSize: 0.6, endSize: 2.4, kind: .smoke,
                    spin: SIMD2(random.spread() * 2, random.spread() * 2)))
            }
        case .campfire:
            break
        }
    }

    /// Flames licking up off something that is on fire.
    private func emitFire(from thing: Thing, dt: Float, index: Int) {
        let rate: Float
        switch thing.kind {
        case .pine, .oak: rate = 26
        case .house: rate = 34
        case .hay: rate = 20
        case .campfire: rate = 16
        }
        things[index].emit += rate * dt
        while things[index].emit >= 1 {
            things[index].emit -= 1
            let spread = thing.kind == .campfire ? 0.45 : thing.radius * 0.8
            let lowest: Float = thing.kind == .campfire ? 0.3 : 0.4
            let height = lowest + random.float() * (thing.kind == .campfire ? 0.3 : thing.height * 0.85)
            addParticle(Particle(
                position: thing.position + SIMD3(random.spread() * spread, random.spread() * spread,
                                                 height),
                velocity: SIMD3(random.spread() * 0.5, random.spread() * 0.5,
                                2.2 + random.float() * 1.5),
                life: 0.55 + random.float() * 0.45,
                startSize: thing.kind == .campfire ? 0.45 : 0.85,
                endSize: 0.15,
                kind: .flame,
                spin: SIMD2(random.spread() * 6, random.spread() * 6)))
        }
    }

    private func steam(at position: SIMD3<Float>) {
        addParticle(Particle(position: position,
                             velocity: SIMD3(random.spread(), random.spread(), 2.4),
                             life: 1.1, startSize: 0.3, endSize: 1.6, kind: .steam,
                             spin: SIMD2(random.spread() * 3, random.spread() * 3)))
    }

    private func burst(at position: SIMD3<Float>, count: Int, color: SIMD3<Float>, speed: Float) {
        for index in 0..<count {
            guard debris.count < Tuning.maxDebris else { return }
            let angle = random.float() * 2 * .pi
            let out = speed * (0.4 + 0.6 * random.float())
            debris.append(Debris(
                position: position,
                velocity: SIMD3(cos(angle) * out, sin(angle) * out, speed * (0.6 + random.float())),
                spin: SIMD3(random.spread(), random.spread(), random.spread()) * 8,
                big: index % 3 == 0,
                color: color))
        }
    }

    private func stepDebris(dt: Float) {
        for index in debris.indices {
            debris[index].age += dt
            debris[index].velocity.z -= 18 * dt
            debris[index].position += debris[index].velocity * dt
            let floor: Float = debris[index].big ? 0.22 : 0.14
            if debris[index].position.z < floor {
                debris[index].position.z = floor
                debris[index].velocity.z = abs(debris[index].velocity.z) * 0.35
                debris[index].velocity.x *= 0.6
                debris[index].velocity.y *= 0.6
                debris[index].spin *= 0.6
            }
        }
        debris.removeAll { $0.age > 3.5 }
    }

    // MARK: - Score and combos

    private func award(_ points: Int, _ label: String, style: Popup.Style) {
        combo += 1
        bestCombo = max(bestCombo, combo)
        comboTimer = Tuning.comboWindow
        let earned = points * multiplier
        score += earned
        pendingPopups.append(Popup(text: "\(label) +\(earned)", style: style))
        if score > best { best = score }
        comboMilestone()
        onPresentationChanged?()
    }

    /// **"Make it say ULTIMATE COMBO and stuff."**
    private func comboMilestone() {
        let name: String?
        switch combo {
        case 3: name = "COMBO!"
        case 5: name = "SUPER COMBO!"
        case 8: name = "MEGA COMBO!!"
        case 12: name = "ULTIMATE COMBO!!!"
        case 16: name = "HYPER ULTIMATE COMBO!!!"
        case 20: name = "WORLD DESTROYER!!!!"
        case let n where n > 20 && n % 5 == 0: name = "ULTIMATE COMBO x\(n)!!!"
        default: name = nil
        }
        guard let name else { return }

        announce(name, subtitle: "x\(combo) in a row · points x\(multiplier)", duration: 1.8,
                 isCombo: true)
        switch combo {
        case ..<8:
            host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: 0.3,
                                    rate: 1.6 + 0.1 * Double(combo))
        case ..<12:
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.45)
        default:
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.5)
        }
    }

    private func endCombo() {
        if combo >= 5 {
            pendingPopups.append(Popup(text: "COMBO OVER · x\(combo)", style: .info))
        }
        combo = 0
        comboTimer = 0
        saveBest()
        onPresentationChanged?()
    }

    private func saveBest() {
        if score > Self.storedBest { UserDefaults.standard.set(score, forKey: Self.bestKey) }
    }

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6,
                  isCombo: Bool = false) {
        announcementSerial += 1
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration,
                                    isCombo: isCombo, serial: announcementSerial)
        onPresentationChanged?()
    }

    // MARK: - Debug

    #if DEBUG
    /// `-destroyworldice`: a frozen tree, house and campfire right beside the track, and one
    /// melting, so the ice can be looked at without having to catch it.
    func debugIceShowcase() {
        let spots: [(Kit.Kind, SIMD3<Float>, State)] = [
            (.pine, SIMD3(-6, 52, 0), .frozen),
            (.house, SIMD3(9, 58, 0), .frozen),
            (.campfire, SIMD3(-4, 44, 0), .frozen),
            (.oak, SIMD3(6, 46, 0), .frozen),
        ]
        for (kind, position, state) in spots {
            nextThingId += 1
            var thing = Thing(id: nextThingId, kind: kind, variant: 1, position: position,
                              heading: kind == .house ? 0 : 0.4)
            thing.state = state
            thing.ice = state == .frozen ? 1 : 0
            thing.char = kind == .campfire ? 0 : 0.4
            things.removeAll {
                simd_distance(SIMD2($0.position.x, $0.position.y), SIMD2(position.x, position.y)) < 8
            }
            things.append(thing)
        }
    }

    /// One line a second for `-destroyworldtrace`.
    var debugTraceLine: String {
        let burning = things.filter { $0.state == .burning }.count
        let frozen = things.filter { $0.state == .frozen }.count
        return String(format: "destroyworld %.0fm look %.2f aim %.2f firing %@ · score %d combo %d best %d · destroyed %d burning %d frozen %d · particles %d debris %d things %d",
                      trainY, look, aimDown, firing ? "yes" : "no", score, combo, bestCombo,
                      destroyedCount, burning, frozen, particles.count, debris.count, things.count)
    }
    #endif

    // MARK: - Scene

    var backgroundColor: String? { Kit.skyHex }

    /// Nobody to draw — you are looking out of your own eyes.
    var sceneCharacters: [MinigameCharacter] { [] }

    var scenePrimitives: [ScenePrimitive] {
        var out = Kit.scenery(trainY: trainY)
        out += Kit.train(trainY: trainY)
        for thing in things { appendThing(thing, to: &out) }
        appendDebris(to: &out)
        appendParticles(to: &out)
        out += Kit.flamethrower(basis: gunBasis, firing: firing, time: elapsed)
        return out
    }

    /// The flamethrower's axes: right, down the barrel, up — with its grip low and to the right
    /// of your eyes, and a little kick when it is firing.
    private var gunBasis: Float4x4 {
        let forward = aimDirection
        let right = rightDirection
        let up = simd_cross(right, forward)
        let kick: Float = firing ? 0.012 * sin(elapsed * 55) : 0
        let grip = eye + forward * (0.5 + kick) + right * 0.2 - up * (0.22 + kick)
        return Float4x4(columns: (SIMD4(right, 0), SIMD4(forward, 0), SIMD4(up, 0),
                                  SIMD4(Kit.m(grip), 1)))
    }

    private func appendThing(_ thing: Thing, to out: inout [ScenePrimitive]) {
        guard let parts = Kit.parts[thing.kind]?[thing.variant] else { return }

        let base = thing.position + SIMD3(thing.shake, 0, -thing.sink)
        var placement = Float4x4.translation(Kit.m(base))
        if thing.fallAngle > 0 {
            // Tip over about the base, towards `fallDirection`.
            placement = placement * Float4x4.rotationZ(thing.fallDirection)
                * Float4x4.rotationY(thing.fallAngle) * Float4x4.rotationZ(-thing.fallDirection)
        }
        placement = placement * Float4x4.rotationZ(thing.heading)

        let frozen = thing.state == .frozen || thing.state == .melting
        let frost = frozen ? 0.85 * min(1, thing.ice * 1.5) : 0
        for part in parts {
            var color = part.color
            if part.burns { color = simd_mix(color, Kit.charcoal, SIMD3(repeating: thing.char * 0.9)) }
            if frost > 0 { color = simd_mix(color, Kit.iceTint, SIMD3(repeating: frost)) }
            out.append(ScenePrimitive(shape: part.shape,
                                      transform: placement * part.local,
                                      color: color,
                                      roughness: frost > 0 ? 0.25 : part.roughness,
                                      castsShadow: thing.kind == .pine || thing.kind == .oak
                                          || thing.kind == .house))
        }

        // A frozen campfire keeps its flames — frozen solid, pale blue, not moving.
        if frozen, thing.kind == .campfire {
            for (index, offset) in [SIMD3<Float>(0, 0, 0.75), SIMD3(0.2, 0.1, 1.15),
                                    SIMD3(-0.15, -0.1, 1.0)].enumerated() {
                let size: Float = index == 0 ? 0.6 : 0.35
                out.append(ScenePrimitive(
                    shape: .box(width: Kit.m(size), height: Kit.m(size), depth: Kit.m(size)),
                    transform: Float4x4.translation(Kit.m(thing.position + offset))
                        * Float4x4.rotationZ(Float(index) + 0.4) * Float4x4.rotationX(0.6),
                    color: SIMD3(0.75, 0.95, 1.0), unlit: true, castsShadow: false))
            }
        }

        // The block of ice, see-through, shrinking in eighths as it melts.
        if frozen, thing.ice > 0.02 {
            let step = max(1, Int((thing.ice * Float(Kit.iceSteps)).rounded()))
            let size = Kit.iceSize(of: thing.kind) * (Float(step) / Float(Kit.iceSteps))
            out.append(ScenePrimitive(
                shape: .box(width: Kit.m(size.x), height: Kit.m(size.y), depth: Kit.m(size.z)),
                transform: Float4x4.translation(Kit.m(thing.position + SIMD3(0, 0, size.z / 2)))
                    * Float4x4.rotationZ(thing.heading),
                // Unlit: lit by the sun, a pale blue box came out cream-coloured.
                color: SIMD3(0.45, 0.85, 1.0), opacity: 0.5, unlit: true, castsShadow: false))
        }

        // The puddle the ice leaves behind.
        if thing.puddle > 0.05 {
            let step = max(1, Int((thing.puddle * 8).rounded()))
            let radius = Float(step) / 8 * (thing.radius + 0.9)
            out.append(ScenePrimitive(
                shape: .cylinder(radius: Kit.m(radius), height: Kit.m(0.04)),
                transform: Float4x4.translation(Kit.m(thing.position + SIMD3(0, 0, 0.12)))
                    * Kit.upright,
                color: SIMD3(0.35, 0.62, 0.92), opacity: 0.75, roughness: 0.05,
                castsShadow: false))
        }
    }

    private func appendDebris(to out: inout [ScenePrimitive]) {
        for piece in debris {
            let size: Float = piece.big ? 0.44 : 0.28
            let turn = piece.spin * piece.age
            out.append(ScenePrimitive(
                shape: .box(width: Kit.m(size), height: Kit.m(size), depth: Kit.m(size)),
                transform: Float4x4.translation(Kit.m(piece.position))
                    * Float4x4.eulerXYZ(turn.x, turn.y, turn.z),
                color: piece.color, roughness: 0.8, castsShadow: false))
        }
    }

    /// Every flame and puff of smoke is a little cube, sized in whole steps so the mesh cache
    /// sees at most a couple of dozen of them.
    private func appendParticles(to out: inout [ScenePrimitive]) {
        let stepSize: Float = 0.12
        for particle in particles {
            let t = min(1, particle.age / particle.life)
            let size = particle.startSize + (particle.endSize - particle.startSize) * t
            let step = max(1, Int((size / stepSize).rounded()))
            let side = Kit.m(Float(step) * stepSize)

            let color: SIMD3<Float>
            let opacity: Float
            switch particle.kind {
            case .flame:
                color = flameColor(t)
                opacity = 0.97 * (1 - t * t * t)
            case .smoke:
                color = SIMD3(0.22, 0.2, 0.19)
                opacity = 0.55 * (1 - t)
            case .chimney:
                color = simd_mix(SIMD3(0.45, 0.45, 0.47), SIMD3(0.85, 0.85, 0.88), SIMD3(repeating: t))
                opacity = 0.6 * (1 - t)
            case .steam:
                color = SIMD3(0.95, 0.98, 1.0)
                opacity = 0.6 * (1 - t)
            }
            guard opacity > 0.02 else { continue }

            let turn = particle.spin * particle.age
            out.append(ScenePrimitive(
                shape: .box(width: side, height: side, depth: side),
                transform: Float4x4.translation(Kit.m(particle.position))
                    * Float4x4.rotationZ(turn.x) * Float4x4.rotationX(turn.y),
                color: color, opacity: opacity, unlit: true, castsShadow: false))
        }
    }

    /// White-hot at the nozzle, then yellow, orange, red, and black smoke at the end.
    private func flameColor(_ t: Float) -> SIMD3<Float> {
        let stops: [(Float, SIMD3<Float>)] = [
            (0, SIMD3(1, 0.92, 0.45)),
            (0.12, SIMD3(1, 0.72, 0.1)),
            (0.4, SIMD3(1, 0.38, 0.02)),
            (0.72, SIMD3(0.82, 0.1, 0.02)),
            (1, SIMD3(0.18, 0.14, 0.13)),
        ]
        for index in 1..<stops.count where t <= stops[index].0 {
            let (t0, c0) = stops[index - 1]
            let (t1, c1) = stops[index]
            return simd_mix(c0, c1, SIMD3(repeating: (t - t0) / (t1 - t0)))
        }
        return stops[stops.count - 1].1
    }

    // MARK: - Camera

    /// **Out of your eyes.** School Escape found the trick: this camera cannot be put anywhere —
    /// it orbits a point on the ground at a fixed distance. So the point on the ground is put
    /// exactly that far in front of you, and the camera's height is chosen to be your eye
    /// height. Then the camera lands inside your head, looking down the track.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let width = Double(viewport.x)
        let height = Double(viewport.y)
        guard width > 0, height > 0 else { return }
        _ = dt

        let fov = Double(camera.fovDegrees) * .pi / 180
        let orbit = height / (2 * tan(fov / 2))
        let eyeUnits = Double(Kit.m(eye.z))
        let pitch = min(acos(min(1, eyeUnits / orbit)), .pi / 2 - 0.02)

        // A wide lens on a landscape screen; wider still on a portrait one, so you can still see
        // to the sides.
        let aspect = width / height
        let wantedSideways = 56.0 * .pi / 180
        camera.zoom = min(0.62, tan(fov / 2) * aspect / tan(wantedSideways / 2))
        camera.pitch = pitch
        camera.yaw = Double(look)
        camera.springX = 0
        camera.springY = 0

        let ahead = sin(pitch) * orbit
        let focusX = Double(Kit.m(eye.x)) - sin(Double(look)) * ahead
        let focusY = Double(Kit.m(eye.y)) + cos(Double(look)) * ahead
        // `Camera.update` nudges its focus up the screen by 15% of the view for a followed
        // player, and takes world Y (which points the other way). Both undone here.
        let headroom = height / camera.zoom * 0.15
        camera.update(playerX: focusX, playerY: headroom - focusY, viewport: viewport, mapData: nil)

        screenCentreDown = Float(.pi / 2 - pitch)
        halfScreenTangent = Float(tan(fov / 2) / camera.zoom)
    }
}

private extension DeterministicRandom {
    mutating func float() -> Float { Float(unit()) }
    /// Between −1 and 1.
    mutating func spread() -> Float { Float(unit()) * 2 - 1 }
}
