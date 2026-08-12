import Foundation
import simd

/// **Five Nights at St Peters** — you are the night security guard, and five children who never
/// went home are trying to get past you and out of the school.
///
/// You sit in the security office. Two corridors lead into it, one from each side, and each has a
/// roller shutter you can drop. A monitor shows seven cameras. The children creep room by room
/// towards you, and if one reaches an open doorway and you have not shut it, they slip past and
/// out of the front gate — night over. Survive from 12 AM to 6 AM and you have kept the school
/// full. Do it five nights running and you get the badge.
///
/// The catch, which is the whole game: **everything you can do to see or stop them costs power,
/// and when the power runs out the shutters go up on their own.** Shut both doors and sit there
/// safe and you are in the dark by 4 AM.
///
/// Three rules make the children more than a timer:
///
/// - **A child you are watching does not move.** The monitor is not just information — pointing
///   it at the corridor somebody is in freezes them there. It is also the reason you cannot just
///   leave it up: it draws power like a closed door.
/// - **Sneaky Sam is the opposite.** He charges up whenever nobody is looking at the playground,
///   and when he is full he runs — and a runner does not queue politely at the door.
/// - **Being blocked costs them.** A child who finds a shut door waits, gives up, and goes back
///   a couple of rooms. That is what a shut door buys: not safety, distance.
/// - **Balloon Barry is meant to get in.** He is the fifth child and the only one who does not
///   end the night — he sits in the office, laughs, and takes your doorway lights away for
///   twenty seconds while the other four keep coming. See `letBarryIn`.
///
/// Structurally this is `SchoolRushGame`'s twin — a `WorldRenderedMinigame` that hands the
/// renderer a cast, a pile of boxes and a camera every frame. The difference is that the world
/// here is built once and stands still (`FiveNightsSchool`), and the camera teleports around it
/// instead of following anybody.
final class FiveNightsGame: WorldRenderedMinigame {

    typealias Side = FiveNightsSchool.Side
    typealias Room = FiveNightsSchool.Room

    // MARK: - Tuning

    enum Tuning {
        /// **20 seconds an hour, so a night is two minutes.** The original is 89 seconds an hour
        /// and a nine-minute night, which is a long time to ask a ten-year-old to stare at a
        /// corridor — and five of them is three quarters of an hour before the badge lands.
        static let hourSeconds: Double = 20
        static let hoursInNight = 6

        /// Power, in per cent per second. `base` is the office lights and the monitor bank you
        /// cannot turn off; every shut door, lit doorway and raised monitor adds `perDevice`.
        ///
        /// The numbers are chosen so that **doing nothing uses about a third of a night** and
        /// **two doors plus the camera runs out just before 5 AM**. That gap is the game.
        static let drainBase: Double = 0.28
        static let drainPerDevice: Double = 0.30

        /// How long a shutter takes to travel, in seconds. Long enough to see, short enough that
        /// pressing the button at the last moment still works.
        static let doorTravel: Double = 0.35

        /// How often each child rolls to move. Their rolls are staggered so they do not all move
        /// on the same beat.
        static let moveInterval: Double = 5.0

        /// How long a child stands at a shut door before giving up.
        static let doorGiveUp: Double = 3.0
        /// How far back down their route giving up sends them.
        static let retreatRooms = 2

        /// The blackout: how long after the power dies before somebody finds you.
        static let blackoutGrace: Double = 10

        /// How long Balloon Barry stays once he is in, with your lights in his pocket. Twenty
        /// seconds is one whole in-game hour — long enough to be a real problem, short enough
        /// that it is not simply the end of the night by another name.
        static let barryVisit: Double = 20

        /// The badge, and the night that earns it.
        static let nights = 5
        static let badgeId = "five nights"
    }

    // MARK: - Phase

    enum Phase {
        /// A night in progress.
        case onDuty
        /// A child got in. The camera is in their face and the panel is up.
        case caught
        /// 6 AM. The bell went and the badge, if this was night five, is claimed.
        case survived
    }

    private(set) var phase: Phase = .onDuty

    // MARK: - The children

    /// One child, and everything about where they are on their way to you.
    ///
    /// `stage` indexes `route`: while it is inside the array the child is standing in that room,
    /// `route.count` means they are in the office doorway, and anything past that means they are
    /// through it and you have lost.
    struct Kid {
        var name: String
        var model: String
        var outfit: String
        /// Which door they come to.
        var side: Side
        /// The rooms they walk through, in order, ending in the corridor outside their door.
        var route: [Room]
        /// Sneaky Sam. See the class comment — he charges instead of rolling, and he does not
        /// wait at the door.
        var sprinter: Bool = false
        /// Balloon Barry. Getting in does not lose the night — see `letBarryIn`.
        var distractor: Bool = false

        /// How likely a roll is to move them, out of 20. Set per night.
        var aggression: Int = 0

        var stage: Int = 0
        /// Seconds until this child's next roll.
        var timer: Double = 0
        /// How long they have stood at a shut door.
        var blockedFor: Double = 0
        /// How long they have stood at an open one. This is your reaction window.
        var breachFor: Double = 0
        /// The sprinter's charge, in seconds of not being watched.
        var charge: Double = 0

        var character: GameCharacter = GameCharacter(id: 0, name: nil)

        var atDoor: Bool { stage == route.count }
        var isIn: Bool { stage > route.count }
        var room: Room? { stage < route.count ? route[stage] : nil }
    }

    private(set) var kids: [Kid] = []

    /// The five of them: three up the west side and two up the east, the way the original splits
    /// its cast between the two doors.
    private static func cast() -> [Kid] {
        [
            Kid(name: "Mad Millie", model: "girl", outfit: "red", side: .west,
                route: [.assemblyHall, .classroom, .westCorridor]),
            Kid(name: "Big Ryan", model: "boy", outfit: "blue", side: .east,
                route: [.assemblyHall, .diningHall, .eastCorridor]),
            Kid(name: "Tilda", model: "girl", outfit: "green", side: .west,
                route: [.assemblyHall, .toilets, .westCorridor]),
            Kid(name: "Sneaky Sam", model: "stylized_boy", outfit: "yellow", side: .east,
                route: [.playground, .eastCorridor], sprinter: true),
            Kid(name: "Balloon Barry", model: "boy", outfit: "ginger", side: .west,
                route: [.assemblyHall, .classroom, .westCorridor], distractor: true),
        ]
    }

    /// How hard each of the five tries, night by night, out of 20.
    ///
    /// Night one is deliberately nearly empty: two children, moving slowly, so the first two
    /// minutes are spent learning what the buttons do rather than losing. Night five is four
    /// children who barely stop, plus Barry.
    ///
    /// The fifth column is Balloon Barry, and it is high from the start on purpose: he is meant
    /// to get in. He costs you your lights, not your night.
    private static let aggressionByNight: [[Int]] = [
        [4, 3, 0, 0, 6],
        [6, 5, 3, 2, 8],
        [9, 8, 6, 5, 10],
        [11, 10, 9, 8, 12],
        [14, 13, 12, 11, 14],
    ]

    /// How long you have to shut the door once somebody is standing in the doorway. Shrinks as
    /// the nights go on, which is most of what makes night five night five.
    private static let breachWindowByNight: [Double] = [6.0, 5.0, 4.5, 4.0, 3.5]
    /// How long Sam charges for before he runs, when nobody is watching the playground.
    private static let sprintChargeByNight: [Double] = [16, 13, 11, 9, 7.5]

    // MARK: - State

    private(set) var night: Int = 1
    /// Seconds into the night. `hoursInNight × hourSeconds` is dawn.
    private(set) var elapsed: Double = 0
    private(set) var power: Double = 100

    /// Where each shutter actually is: 0 fully up, 1 fully down. Eased, so it can be caught
    /// halfway — a door that is 0.6 of the way down already blocks.
    private var shutterPosition: [Side: Double] = [.west: 0, .east: 0]
    private var shutterTarget: [Side: Double] = [.west: 0, .east: 0]
    private var lightsOn: [Side: Bool] = [.west: false, .east: false]

    private(set) var tabletUp = false
    private(set) var currentCam: Room = .assemblyHall
    /// Bumped every time the feed changes, so the HUD knows to flash its static.
    private(set) var camFlashToken = 0

    private(set) var powerOut = false
    private var blackoutFor: Double = 0
    /// Who got in, for the panel and for the shot the camera ends on.
    private(set) var caughtBy: Kid?

    /// **Balloon Barry's visit.** Seconds left of it, and which slot in the cast he is, so he can
    /// be drawn standing in the office grinning at you.
    ///
    /// He is the one child getting in does not end the night for. What he does instead is worse
    /// in the moment: he sits on the desk and pulls the fuse for the doorway lights, so for
    /// twenty seconds you cannot see who is standing at either door — and Millie and Tilda are
    /// still coming. He is a distraction in the exact sense the original means it: nothing about
    /// him hurts you, and everything about him makes you take your eye off what does.
    private(set) var barryFor: Double = 0
    private var barryIndex: Int?
    /// True while the doorway lights are out. The light buttons do nothing and say so.
    var lightsBroken: Bool { barryFor > 0 }

    private var random = DeterministicRandom(seed: 5)
    private var active = false

    /// The highest night survived, remembered between sessions the way School Rush remembers its
    /// best run. It is what lets night three be a thing you come back to.
    private(set) var nightsSurvived: Int = FiveNightsGame.storedNights

    private static let nightsKey = "fivenights.survived"
    private static var storedNights: Int { UserDefaults.standard.integer(forKey: nightsKey) }

    private var badgeClaimed = false

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    private(set) var announcement: Announcement?

    /// Raised whenever something the HUD shows changes, so it can refresh without polling.
    var onPresentationChanged: (() -> Void)?

    unowned let host: MinigameHost

    // MARK: - Numbers the HUD reads

    var hour: Int { min(Tuning.hoursInNight, Int(elapsed / Tuning.hourSeconds)) }

    /// "12 AM" through "6 AM". Midnight is 12, not 0, which is the one thing everybody gets wrong.
    var clockText: String { hour == 0 ? "12 AM" : "\(hour) AM" }

    /// How far through the night, 0 to 1 — the clock's progress bar.
    var nightProgress: Double {
        min(1, elapsed / (Double(Tuning.hoursInNight) * Tuning.hourSeconds))
    }

    func doorClosed(_ side: Side) -> Bool { (shutterTarget[side] ?? 0) > 0.5 }
    func doorPosition(_ side: Side) -> Double { shutterPosition[side] ?? 0 }
    func lightOn(_ side: Side) -> Bool { lightsOn[side] ?? false }

    /// A shutter is a door once it is most of the way down. Anything less and a child walks under
    /// it — which is fair, and is why the travel time matters.
    private func blocks(_ side: Side) -> Bool { (shutterPosition[side] ?? 0) > 0.6 }

    /// How many bars the usage meter shows: one for being awake, plus one per thing switched on.
    /// Straight out of the original, where it is the only warning you get.
    var usageBars: Int {
        var bars = 1
        for side in [Side.west, .east] {
            if doorClosed(side) { bars += 1 }
            if lightOn(side) { bars += 1 }
        }
        if tabletUp { bars += 1 }
        // He is sitting on the desk pressing everything. It shows on the meter.
        if lightsBroken { bars += 1 }
        return bars
    }

    var cameraName: String { FiveNightsSchool.plan(currentCam).name }
    var cameraNumber: Int { FiveNightsSchool.cameraNumber(of: currentCam) }

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        // `npcs` and `myCharacter` are what the map happened to be carrying. This game's cast is
        // four named children rather than a crowd, and the guard is the camera rather than a
        // body, so neither is used — the parameters are here because every minigame is built
        // the same way (`GameState.startMinigame`).
        _ = npcs
        _ = myCharacter
    }

    func start() {
        active = true
        // Carry on from the furthest night reached, so night three is not five minutes of night
        // one every time. A fresh player starts at one; somebody who has survived three starts
        // on four.
        night = min(Tuning.nights, nightsSurvived + 1)
        Log.world("[FiveNights] Starting on night \(night) (survived \(nightsSurvived))")
        beginNight(night)
        host.minigamePlayBackground(path: "/media/ticking_clock.mp3", volume: 0.35)
    }

    /// Everything a fresh night resets.
    func beginNight(_ number: Int) {
        night = min(Tuning.nights, max(1, number))
        random.reseed(0x5F_1_9_47 &+ UInt64(night) &* 6247 &+ UInt64(elapsed * 1000))

        elapsed = 0
        power = 100
        powerOut = false
        blackoutFor = 0
        caughtBy = nil
        barryFor = 0
        barryIndex = nil
        phase = .onDuty
        tabletUp = false
        currentCam = .assemblyHall
        shutterPosition = [.west: 0, .east: 0]
        shutterTarget = [.west: 0, .east: 0]
        lightsOn = [.west: false, .east: false]
        badgeClaimed = false

        let aggression = Self.aggressionByNight[night - 1]
        kids = Self.cast().enumerated().map { index, template in
            var kid = template
            kid.aggression = aggression[index]
            kid.stage = 0
            // Staggered, so four children never roll on the same frame and arrive in a lump.
            kid.timer = Tuning.moveInterval * (0.4 + 0.25 * Double(index))
            kid.blockedFor = 0
            kid.breachFor = 0
            kid.charge = 0
            kid.character = GameCharacter(id: 9300 + index, name: kid.name)
            kid.character.model = kid.model
            kid.character.outfit = kid.outfit
            kid.character.hide_nameplate = true
            kid.character.rotation = 90
            kid.character.z = 0
            return kid
        }

        announce("NIGHT \(night)", subtitle: "12 AM · keep them in", duration: 2.6)
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.25)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        host.minigameStopBackground()
    }

    /// The exit button in the button bar.
    func requestExit() {
        host.minigameShowDialog("Clock off and go back to school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    // MARK: - Controls

    func toggleDoor(_ side: Side) {
        guard phase == .onDuty, !powerOut else { return }
        let closing = !doorClosed(side)
        shutterTarget[side] = closing ? 1 : 0
        // A roller shutter, played back deep: `clap` at two-fifths speed is a very passable
        // clang, and it is already in the bundle.
        host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.5, rate: closing ? 0.4 : 0.7)
        onPresentationChanged?()
    }

    func toggleLight(_ side: Side) {
        guard phase == .onDuty, !powerOut else { return }
        guard !lightsBroken else {
            announce("CLICK. CLICK.", subtitle: "Barry has the light switch", duration: 1.4)
            return
        }
        lightsOn[side] = !(lightsOn[side] ?? false)
        // Only one light at a time — pressing one turns the other off. It halves the power a
        // careless player can burn and it makes checking a door a decision.
        if lightsOn[side] == true { lightsOn[side.other] = false }
        onPresentationChanged?()
    }

    func setTablet(_ up: Bool) {
        guard phase == .onDuty, !powerOut else { return }
        guard tabletUp != up else { return }
        tabletUp = up
        camFlashToken += 1
        host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.25, rate: 0.6)
        onPresentationChanged?()
    }

    func selectCam(_ room: Room) {
        guard phase == .onDuty, !powerOut, tabletUp else { return }
        guard currentCam != room else { return }
        currentCam = room
        camFlashToken += 1
        host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.2, rate: 0.8)
        onPresentationChanged?()
    }

    /// The panel's buttons.
    func retryNight() { beginNight(night) }
    func nextNight() { beginNight(min(Tuning.nights, night + 1)) }

    // MARK: - Update

    func update(dt: Double) {
        guard active else { return }

        if var current = announcement {
            current.remaining -= dt
            announcement = current.remaining > 0 ? current : nil
            if announcement == nil { onPresentationChanged?() }
        }

        stepShutters(dt: dt)

        guard phase == .onDuty else { return }

        stepClock(dt: dt)
        guard phase == .onDuty else { return }

        stepBarry(dt: dt)
        stepPower(dt: dt)
        for index in kids.indices { stepKid(index, dt: dt) }
        stepBlackout(dt: dt)
    }

    /// The shutters ease rather than snap, in seconds so a 120 Hz display does not close them
    /// twice as fast.
    private func stepShutters(dt: Double) {
        for side in [Side.west, .east] {
            let target = shutterTarget[side] ?? 0
            let position = shutterPosition[side] ?? 0
            guard abs(target - position) > 0.001 else {
                shutterPosition[side] = target
                continue
            }
            let step = dt / Tuning.doorTravel
            shutterPosition[side] = position + max(-step, min(step, target - position))
        }
    }

    private func stepClock(dt: Double) {
        let before = hour
        elapsed += dt
        if hour != before, hour < Tuning.hoursInNight {
            announce(clockText, duration: 1.4)
        }
        if elapsed >= Double(Tuning.hoursInNight) * Tuning.hourSeconds {
            survive()
        }
    }

    private func stepPower(dt: Double) {
        guard !powerOut else { return }
        power -= (Tuning.drainBase + Tuning.drainPerDevice * Double(usageBars - 1)) * dt
        guard power <= 0 else { return }

        // The lights go out, the shutters roll up on their own, and the monitor dies. Whatever
        // was on the other side of those doors is now simply on its way in.
        power = 0
        powerOut = true
        tabletUp = false
        lightsOn = [.west: false, .east: false]
        shutterTarget = [.west: 0, .east: 0]
        blackoutFor = 0
        announce("POWER OUT", subtitle: "The shutters are going up", duration: 3)
        host.minigamePlayEffect(path: "/media/fail.mp3", volume: 0.5)
        host.minigamePlayEffect(path: "/media/violin.mp3", volume: 0.4)
        onPresentationChanged?()
    }

    /// In the dark there is nothing to do but hope the bell goes first. Ten seconds, and then
    /// whoever was closest walks in.
    private func stepBlackout(dt: Double) {
        guard powerOut, phase == .onDuty else { return }
        blackoutFor += dt
        guard blackoutFor >= Tuning.blackoutGrace else { return }
        let index = kids.indices.max(by: { kids[$0].stage < kids[$1].stage }) ?? 0
        caught(by: index)
    }

    // MARK: - One child

    private func stepKid(_ index: Int, dt: Double) {
        // Already at the doorway: this is the part with the timer on it.
        if kids[index].atDoor {
            stepKidAtDoor(index, dt: dt)
            return
        }
        guard !kids[index].isIn else { return }

        if kids[index].sprinter {
            stepSprinter(index, dt: dt)
            return
        }

        // **A child you are looking at does not move.** Their timer still runs down, so pointing
        // the camera at somebody buys exactly as long as you keep it there and not a second more.
        kids[index].timer -= dt
        guard kids[index].timer <= 0 else { return }
        kids[index].timer = Tuning.moveInterval

        if isWatched(kids[index].room) { return }
        guard kids[index].aggression > 0 else { return }
        guard random.chance(Double(kids[index].aggression) / 20) else { return }

        advance(index)
    }

    /// Sam does not roll. He fills up whenever nobody is looking at him, and when he is full he
    /// moves — which means the only way to keep him back is to check the playground, and the only
    /// cost of checking the playground is the power it burns.
    private func stepSprinter(_ index: Int, dt: Double) {
        guard kids[index].aggression > 0 else { return }
        if isWatched(kids[index].room) {
            // Watching him does not just pause him, it winds him back down — slowly.
            kids[index].charge = max(0, kids[index].charge - dt * 0.7)
            return
        }
        kids[index].charge += dt
        let full = Self.sprintChargeByNight[night - 1]
        guard kids[index].charge >= full else { return }
        kids[index].charge = 0
        advance(index)
        // Footsteps, so his one warning is a sound rather than nothing at all.
        host.minigamePlayEffect(path: "/media/walking.mp3", volume: 0.5, rate: 1.4)
    }

    private func advance(_ index: Int) {
        kids[index].stage += 1
        if kids[index].atDoor {
            kids[index].blockedFor = 0
            kids[index].breachFor = 0
            // A knock at the door. You are meant to hear this and check the light.
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.35, rate: 0.8)
        }
        onPresentationChanged?()
    }

    private func stepKidAtDoor(_ index: Int, dt: Double) {
        let side = kids[index].side

        if blocks(side) {
            kids[index].breachFor = 0
            kids[index].blockedFor += dt
            guard kids[index].blockedFor >= Tuning.doorGiveUp else { return }
            // Gave up. A bang on the shutter, and back down the corridor — that is what the door
            // actually buys you.
            kids[index].blockedFor = 0
            kids[index].stage = max(0, kids[index].route.count - 1 - Tuning.retreatRooms)
            kids[index].timer = Tuning.moveInterval
            kids[index].charge = 0
            host.minigamePlayEffect(path: "/media/buzzer.mp3", volume: 0.3, rate: 1.6)
            announce("BANG!", subtitle: "Somebody gave up on the \(side.label.lowercased()) door",
                     duration: 1.8)
            onPresentationChanged?()
            return
        }

        kids[index].blockedFor = 0
        kids[index].breachFor += dt
        // The sprinter does not queue. Everybody else gives you the night's window.
        let window = kids[index].sprinter
            ? min(2.5, Self.breachWindowByNight[night - 1] * 0.6)
            : Self.breachWindowByNight[night - 1]
        guard kids[index].breachFor >= window else { return }
        if kids[index].distractor {
            letBarryIn(index)
            return
        }
        kids[index].stage += 1
        caught(by: index)
    }

    /// **Barry gets in, and the night carries on.** He goes straight back to the start of his
    /// own route afterwards, so he can do it again — which he will.
    private func letBarryIn(_ index: Int) {
        barryFor = Tuning.barryVisit
        barryIndex = index
        kids[index].stage = 0
        kids[index].timer = Tuning.moveInterval * 2
        kids[index].breachFor = 0
        lightsOn = [.west: false, .east: false]
        Log.world("[FiveNights] Balloon Barry is in — lights out for \(Int(Tuning.barryVisit)) s")
        host.minigamePlayEffect(path: "/media/laugh.mp3", volume: 0.55)
        announce("BALLOON BARRY IS IN", subtitle: "He has got the doorway lights", duration: 2.4)
        onPresentationChanged?()
    }

    /// His twenty seconds, and the laugh every few of them so you cannot forget he is there.
    private func stepBarry(dt: Double) {
        guard barryFor > 0 else { return }
        let before = barryFor
        barryFor -= dt
        // A laugh every five seconds, on the same beats however long the visit is.
        if Int(before / 5) != Int(barryFor / 5) {
            host.minigamePlayEffect(path: "/media/laugh.mp3", volume: 0.35, rate: 1.15)
        }
        guard barryFor <= 0 else { return }
        barryFor = 0
        barryIndex = nil
        announce("The lights are back", duration: 1.4)
        onPresentationChanged?()
    }

    /// Whether the monitor is up and pointed at this room. `nil` — a child in a doorway — is
    /// never watched, which is the point of the doorway lights.
    private func isWatched(_ room: Room?) -> Bool {
        guard tabletUp, let room else { return false }
        return room == currentCam
    }

    // MARK: - Ending a night

    private func caught(by index: Int) {
        guard phase == .onDuty else { return }
        phase = .caught
        caughtBy = kids[index]
        barryFor = 0
        barryIndex = nil
        Log.world("[FiveNights] Night \(night): \(kids[index].name) got past at \(clockText)")
        host.minigamePlayEffect(path: "/media/laugh.mp3", volume: 0.7)
        host.minigamePlayEffect(path: "/media/buzzer.mp3", volume: 0.5)
        host.minigameStopBackground()
        onPresentationChanged?()
    }

    private func survive() {
        guard phase == .onDuty else { return }
        phase = .survived
        barryFor = 0
        barryIndex = nil
        Log.world("[FiveNights] Survived night \(night)")
        host.minigameStopBackground()
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.45)
        host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.4)

        if night > nightsSurvived {
            nightsSurvived = night
            UserDefaults.standard.set(night, forKey: Self.nightsKey)
        }
        if night >= Tuning.nights, !badgeClaimed {
            badgeClaimed = true
            host.minigameAwardBadge(Tuning.badgeId)
        }
        onPresentationChanged?()
    }

    // MARK: - Presentation

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    /// The title on the end-of-night panel.
    /// **Nothing in this game hurts anybody**, and the words on screen are where that is decided.
    /// A child who reaches the office has not caught you — they have got past you and out of the
    /// front gate, and the night is lost because the school is one pupil short in the morning.
    var endTitle: String {
        switch phase {
        case .survived: return night >= Tuning.nights ? "6 AM — BADGE!" : "6 AM"
        case .caught: return powerOut ? "Lights out" : "One got out!"
        case .onDuty: return ""
        }
    }

    var endDetail: String {
        switch phase {
        case .survived:
            var lines = ["Night \(night) survived with \(Int(power))% power left."]
            lines.append(night >= Tuning.nights
                ? "Five nights at St Peters. Nobody escaped. The badge is yours."
                : "Night \(night + 1) is harder.")
            return lines.joined(separator: "\n")
        case .caught:
            let name = caughtBy?.name ?? "Somebody"
            var lines = powerOut
                ? ["The power died at \(clockText) and \(name) strolled straight out."]
                : ["\(name) slipped past the \(caughtBy?.side.label.lowercased() ?? "") door "
                    + "at \(clockText) and legged it home."]
            lines.append("One pupil short in the morning. Try night \(night) again.")
            return lines.joined(separator: "\n")
        case .onDuty:
            return ""
        }
    }

    var backgroundColor: String? { FiveNightsSchool.nightHex }

    // MARK: - Scene

    /// Only what you could actually see is drawn. On the monitor that is the room the feed is
    /// pointed at; in the office it is whichever doorway you have the light on; and when you have
    /// been caught it is the one person left to look at.
    var sceneCharacters: [MinigameCharacter] {
        if phase == .caught, var kid = caughtBy {
            kid.character.x = FiveNightsSchool.officeFloor.x
            kid.character.y = FiveNightsSchool.officeFloor.y
            kid.character.rotation = 90
            return [MinigameCharacter(character: kid.character, gait: .still)]
        }

        var out: [MinigameCharacter] = []
        // Two children in one room would stand in the same spot, so each takes the slot of its
        // own place in the cast.
        for (index, kid) in kids.enumerated() {
            var character = kid.character
            // Barry, in the office, on the desk, in plain sight — he is the only child you can
            // see without a light, because being seen is the entire point of him.
            if index == barryIndex, barryFor > 0 {
                character.x = FiveNightsSchool.barryPerch.x
                character.y = FiveNightsSchool.barryPerch.y
                character.rotation = 90
                out.append(MinigameCharacter(character: character, gait: .still))
                continue
            }
            if kid.isIn {
                character.x = FiveNightsSchool.officeFloor.x
                character.y = FiveNightsSchool.officeFloor.y
            } else if kid.atDoor {
                // In the doorway you are invisible unless the light is on. That is the whole
                // reason the light button exists.
                guard !tabletUp, lightOn(kid.side) else { continue }
                let spot = FiveNightsSchool.doorway(kid.side)
                character.x = spot.x
                character.y = spot.y
            } else if let room = kid.room, tabletUp, room == currentCam {
                let spot = FiveNightsSchool.slot(room, index: index)
                character.x = spot.x
                character.y = spot.y
            } else {
                continue
            }
            character.rotation = 90
            out.append(MinigameCharacter(character: character, gait: .still))
        }
        return out
    }

    /// Two authored models in the whole game: the bus through the dining hall wall, and the
    /// playground out the back. Everything else is boxes.
    var sceneModels: [SceneModel] {
        [FiveNightsSchool.crashedBus, FiveNightsSchool.playgroundModel]
    }

    var scenePrimitives: [ScenePrimitive] {
        var out = FiveNightsSchool.building
        for side in [Side.west, .east] {
            out.append(contentsOf: FiveNightsSchool.shutter(side, closed: doorPosition(side)))
            if lightOn(side) {
                out.append(contentsOf: FiveNightsSchool.doorwayLight(side))
            }
        }
        return out
    }

    // MARK: - Camera

    /// Three shots, and it cuts between them rather than panning: the office, whichever feed is
    /// up, and — once — a child's face.
    ///
    /// A cut rather than a pan is deliberate. The monitor in the original does not glide from
    /// camera to camera, it snaps with a burst of static, and a camera that eased across the
    /// building would also quietly show you every room on the way.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }
        _ = dt

        var focusX: Double
        var focusY: Double
        var width: Double
        var pitch: Double

        switch phase {
        case .caught:
            // Right in their face, from just above eye level.
            focusX = FiveNightsSchool.officeFloor.x
            focusY = FiveNightsSchool.officeFloor.y
            width = 2.4
            pitch = 1.30
        case .onDuty, .survived:
            if tabletUp {
                let view = FiveNightsSchool.view(of: currentCam)
                focusX = view.x
                focusY = view.y
                width = view.widthMetres
                // Corridors are long and thin; a little more tip shows the length of them.
                pitch = currentCam == .westCorridor || currentCam == .eastCorridor ? 1.10 : 0.98
            } else {
                focusX = FiveNightsSchool.officeView.x
                focusY = FiveNightsSchool.officeView.y
                width = FiveNightsSchool.officeView.widthMetres
                pitch = 1.05
            }
        }

        camera.zoom = max(0.3, viewportWidth / FiveNightsSchool.metres(width))
        camera.pitch = pitch
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        // **Cancel the camera's headroom bias.** `Camera.update` shifts its focus up the screen
        // by 15% of the visible height so a *followed player* sits low in frame with room to see
        // ahead. Nothing is being followed here — the subject is a room — and on a tall screen
        // that bias is five metres, which put the office at the bottom of the picture and the
        // assembly hall in the middle of it. Adding it back means every feed is centred on the
        // room it is named after, whatever shape the screen is.
        let headroom = Double(viewport.y) / camera.zoom * 0.15
        camera.update(playerX: focusX, playerY: focusY + headroom, viewport: viewport,
                      mapData: nil)
    }
}
