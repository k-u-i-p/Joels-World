import Foundation
import simd

/// **Five Nights at St Peters** — you are the night security guard, and five children who never
/// went home are trying to get out of the building.
///
/// There is **one door**. It is the school's front entrance, at the far end of the main entrance
/// hall, and you can see it on **CAM 7**. You sit in the security office with a monitor and a
/// button that drops the shutter over that door, and nothing else. No office doors, no torch, no
/// second way out — one door, seven cameras, and a battery.
///
/// A child works their way room by room towards the entrance hall. When one of them steps up to
/// the front doors you have **seven seconds**. Get the shutter down inside that and they give up,
/// bang on it and go back a couple of rooms. Miss it and they are out of the gate and gone, and
/// the school is a pupil short in the morning. Nobody is ever hurt in this game — the thing you
/// lose is a child off the register.
///
/// Survive 12 AM to 6 AM five nights running and the badge is yours.
///
/// The catch, which is the whole game: **the shutter and the monitor both eat power, and when the
/// power dies the shutter goes up on its own.** Leaving it shut all night is not a strategy; it
/// is a slower way of losing.
///
/// Three rules make the children more than a timer:
///
/// - **A child you are watching does not move.** Pointing the monitor at somebody freezes them
///   where they stand — including in the entrance hall, one step from the door. That is what the
///   cameras are *for*, and it is why you cannot simply leave the monitor down.
/// - **Sneaky Sam is the opposite.** He charges up whenever nobody is looking at the playground,
///   and when he is full he goes straight to the entrance. Checking CAM 6 is the only brake.
/// - **Balloon Barry is meant to get in.** He is not trying to escape; he is trying to be a
///   nuisance. He walks into the office, pulls the fuse on the camera system, and for fifteen
///   seconds you have no monitor at all — while the other four keep walking. See `letBarryIn`.
///
/// Structurally this is `SchoolRushGame`'s twin — a `WorldRenderedMinigame` that hands the
/// renderer a cast, a pile of boxes and a camera every frame. The difference is that the world
/// here is built once and stands still (`FiveNightsSchool`), and the camera teleports around it
/// instead of following anybody.
final class FiveNightsGame: WorldRenderedMinigame {

    typealias Room = FiveNightsSchool.Room

    // MARK: - Tuning

    enum Tuning {
        /// **20 seconds an hour, so a night is two minutes.** The original is 89 seconds an hour
        /// and a nine-minute night, which is a long time to ask a ten-year-old to stare at a
        /// corridor — and five of them is three quarters of an hour before the badge lands.
        static let hourSeconds: Double = 20
        static let hoursInNight = 6

        /// **Seven seconds from stepping up to the door to being through it.** Joel's number, and
        /// it is the one dial that does not move between nights: what changes as the nights go on
        /// is how often somebody is standing there, not how long you get.
        static let exitWait: Double = 7

        /// Power, in per cent per second. `base` is the office and the monitor bank you cannot
        /// turn off; the shutter and the raised monitor add `perDevice` each.
        ///
        /// Chosen so that **doing nothing uses about a third of a night**, **the shutter left
        /// down all night just barely runs out**, and **the shutter and the monitor together die
        /// at about 4 AM**. That gap is the game.
        static let drainBase: Double = 0.30
        static let drainPerDevice: Double = 0.45

        /// How long the shutter takes to travel, in seconds. It is a big one, so it is not quick
        /// — but it is comfortably inside the seven seconds if you start it when you should.
        static let doorTravel: Double = 0.9

        /// How often each child rolls to move. Their rolls are staggered so they do not all move
        /// on the same beat.
        static let moveInterval: Double = 5.0

        /// How long a child stands at a shut shutter before giving up.
        static let doorGiveUp: Double = 3.0
        /// How far back down their route giving up sends them.
        static let retreatRooms = 2

        /// The blackout: how long after the power dies before somebody simply walks out.
        static let blackoutGrace: Double = 10

        /// How long Balloon Barry has your camera system for. Fifteen seconds is most of an
        /// in-game hour of not being able to see anything at all.
        static let barryVisit: Double = 15

        /// The badge, and the night that earns it.
        static let nights = 5
        static let badgeId = "five nights"
    }

    // MARK: - Phase

    enum Phase {
        /// A night in progress.
        case onDuty
        /// Somebody got out of the front door. The camera is on them and the panel is up.
        case escaped
        /// 6 AM. The bell went and the badge, if this was night five, is claimed.
        case survived
    }

    private(set) var phase: Phase = .onDuty

    // MARK: - The children

    /// One child, and where they are on their way to the front door.
    ///
    /// `stage` indexes `route`: while it is inside the array the child is standing in that room,
    /// and `route.count` means they have taken the last step — up to the front doors for the four
    /// who are escaping, into the office for Barry.
    struct Kid {
        var name: String
        var model: String
        var outfit: String
        /// The rooms they walk through, in order. The last one is the entrance hall — except for
        /// Barry, whose last one is the corridor outside the office.
        var route: [Room]
        /// Sneaky Sam. He charges instead of rolling; see `stepSprinter`.
        var sprinter: Bool = false
        /// Balloon Barry. He is not escaping — see `letBarryIn`.
        var distractor: Bool = false

        /// How likely a roll is to move them, out of 20. Set per night.
        var aggression: Int = 0

        var stage: Int = 0
        /// Seconds until this child's next roll.
        var timer: Double = 0
        /// How long they have stood at a shut shutter.
        var blockedFor: Double = 0
        /// How long they have been at the front doors. This is the seven seconds.
        var atDoorFor: Double = 0
        /// The sprinter's charge, in seconds of not being watched.
        var charge: Double = 0

        var character: GameCharacter = GameCharacter(id: 0, name: nil, width: 40, height: 40)

        /// Taken the last step of their route: at the front doors, or in the office for Barry.
        var isAtEnd: Bool { stage == route.count }
        /// Out of the building.
        var isThrough: Bool { stage > route.count }
        var room: Room? { stage < route.count ? route[stage] : nil }
    }

    private(set) var kids: [Kid] = []

    /// The five of them. Four routes to the front door, and Barry.
    private static func cast() -> [Kid] {
        [
            Kid(name: "Mad Millie", model: "girl", outfit: "red",
                route: [.assemblyHall, .classroom, .westCorridor, .mainEntrance]),
            Kid(name: "Big Ryan", model: "boy", outfit: "blue",
                route: [.assemblyHall, .diningHall, .mainEntrance]),
            Kid(name: "Tilda", model: "girl", outfit: "green",
                route: [.assemblyHall, .toilets, .westCorridor, .mainEntrance]),
            Kid(name: "Sneaky Sam", model: "stylized_boy", outfit: "yellow",
                route: [.playground, .mainEntrance], sprinter: true),
            Kid(name: "Balloon Barry", model: "boy", outfit: "ginger",
                route: [.assemblyHall, .classroom, .westCorridor], distractor: true),
        ]
    }

    /// How hard each of the five tries, night by night, out of 20.
    ///
    /// Night one is deliberately nearly empty: two children, moving slowly, so the first two
    /// minutes are spent learning what the two buttons do rather than losing. Night five is four
    /// children who barely stop, plus Barry.
    ///
    /// **This table is the difficulty**, now that the seven seconds never change. A child rolling
    /// at 14/20 every five seconds is in the entrance hall inside half a minute.
    private static let aggressionByNight: [[Int]] = [
        [4, 3, 0, 0, 6],
        [6, 5, 3, 2, 8],
        [9, 8, 6, 5, 10],
        [11, 10, 9, 8, 12],
        [14, 13, 12, 11, 14],
    ]

    /// How long Sam charges for before he moves, when nobody is watching the playground.
    private static let sprintChargeByNight: [Double] = [16, 13, 11, 9, 7.5]

    // MARK: - State

    private(set) var night: Int = 1
    /// Seconds into the night. `hoursInNight × hourSeconds` is dawn.
    private(set) var elapsed: Double = 0
    private(set) var power: Double = 100

    /// Where the shutter actually is: 0 fully up, 1 fully down. Eased, so it can be caught
    /// halfway — and halfway does not stop anybody.
    private(set) var mainDoorPosition: Double = 0
    /// Where the button says it should be.
    private(set) var mainDoorClosed = false

    private(set) var tabletUp = false
    private(set) var currentCam: Room = .assemblyHall
    /// Bumped every time the feed changes, so the HUD knows to flash its static.
    private(set) var camFlashToken = 0

    private(set) var powerOut = false
    private var blackoutFor: Double = 0
    /// Who got out, for the panel and for the shot the camera ends on.
    private(set) var escapee: Kid?

    /// **Balloon Barry's visit.** Seconds left of it, and which slot in the cast he is, so he can
    /// be drawn standing in the office grinning at you.
    ///
    /// Nothing he does hurts you directly, and everything he does makes you take your eye off
    /// what does: while he is in, the whole camera system is dead.
    private(set) var barryFor: Double = 0
    private var barryIndex: Int?

    /// True while Barry has the fuse: no monitor, and the button says so.
    var camerasBroken: Bool { barryFor > 0 }

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

    /// A shutter is a door once it is most of the way down. Anything less and a child ducks under
    /// it — which is fair, and is why the travel time matters.
    private var doorBlocks: Bool { mainDoorPosition > 0.75 }

    /// How many bars the usage meter shows: one for being awake, plus one per thing switched on.
    /// Straight out of the original, where it is the only warning you get.
    var usageBars: Int {
        var bars = 1
        if mainDoorClosed { bars += 1 }
        if tabletUp { bars += 1 }
        if camerasBroken { bars += 1 }
        return bars
    }

    /// **Seconds left before whoever is at the front doors is through them**, or nil when nobody
    /// is there.
    ///
    /// The HUD only shows the number while the monitor is actually pointed at CAM 7 — see
    /// `FiveNightsView`. Everywhere else you get the bang on the door and the banner, and you
    /// have to decide whether to spend the power looking.
    var exitCountdown: Double? {
        guard let kid = kids.first(where: { $0.isAtEnd && !$0.distractor }) else { return nil }
        return max(0, Tuning.exitWait - kid.atDoorFor)
    }

    /// Whether the monitor is up and pointed at the front door.
    var watchingExit: Bool { tabletUp && !camerasBroken && currentCam == .mainEntrance }

    var cameraName: String { FiveNightsSchool.plan(currentCam).name }
    var cameraNumber: Int { FiveNightsSchool.cameraNumber(of: currentCam) }

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        // `npcs` and `myCharacter` are what the map happened to be carrying. This game's cast is
        // five named children rather than a crowd, and the guard is the camera rather than a
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
        random.reseed(0x5F_1_9_47 &+ UInt64(night) &* 6247 &+ UInt64(max(0, elapsed) * 1000))

        elapsed = 0
        power = 100
        powerOut = false
        blackoutFor = 0
        escapee = nil
        barryFor = 0
        barryIndex = nil
        phase = .onDuty
        tabletUp = false
        currentCam = .assemblyHall
        mainDoorPosition = 0
        mainDoorClosed = false
        badgeClaimed = false

        let aggression = Self.aggressionByNight[night - 1]
        kids = Self.cast().enumerated().map { index, template in
            var kid = template
            kid.aggression = aggression[index]
            kid.stage = 0
            // Staggered, so five children never roll on the same frame and arrive in a lump.
            kid.timer = Tuning.moveInterval * (0.4 + 0.2 * Double(index))
            kid.blockedFor = 0
            kid.atDoorFor = 0
            kid.charge = 0
            kid.character = GameCharacter(id: 9300 + index, name: kid.name,
                                          width: 40, height: 40)
            kid.character.model = kid.model
            kid.character.outfit = kid.outfit
            kid.character.hide_nameplate = true
            kid.character.rotation = 90
            kid.character.z = 0
            return kid
        }

        announce("NIGHT \(night)", subtitle: "12 AM · nobody leaves", duration: 2.6)
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.25)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        host.minigameStopBackground()
    }

    /// The exit button in the button bar.
    ///
    /// **Out onto the campus, whichever door you came in by.** There are two ways in now — the
    /// security office in the main building and Mr Hardy on the campus — and a minigame is not
    /// told which map it was started from, so it cannot put you back on it. The campus is the
    /// right answer anyway: your shift has ended and you are walking out of the building.
    func requestExit() {
        host.minigameShowDialog("Clock off and go home?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    // MARK: - Controls

    /// **The one button that matters.** Everything else in this game is information.
    func toggleMainDoor() {
        guard phase == .onDuty, !powerOut else { return }
        mainDoorClosed.toggle()
        // A roller shutter, played back deep: `clap` at two-fifths speed is a very passable
        // clang, and it is already in the bundle.
        host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.55,
                                rate: mainDoorClosed ? 0.4 : 0.7)
        onPresentationChanged?()
    }

    func setTablet(_ up: Bool) {
        guard phase == .onDuty, !powerOut else { return }
        guard !camerasBroken else {
            announce("NO SIGNAL", subtitle: "Barry has pulled the camera fuse", duration: 1.4)
            return
        }
        guard tabletUp != up else { return }
        tabletUp = up
        camFlashToken += 1
        host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.25, rate: 0.6)
        onPresentationChanged?()
    }

    func selectCam(_ room: Room) {
        guard phase == .onDuty, !powerOut, tabletUp, !camerasBroken else { return }
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

        stepDoor(dt: dt)

        guard phase == .onDuty else { return }

        stepClock(dt: dt)
        guard phase == .onDuty else { return }

        stepBarry(dt: dt)
        stepPower(dt: dt)
        for index in kids.indices { stepKid(index, dt: dt) }
        stepBlackout(dt: dt)
    }

    /// The shutter eases rather than snaps, in seconds so a 120 Hz display does not close it
    /// twice as fast.
    private func stepDoor(dt: Double) {
        let target: Double = mainDoorClosed ? 1 : 0
        guard abs(target - mainDoorPosition) > 0.001 else {
            mainDoorPosition = target
            return
        }
        let step = dt / Tuning.doorTravel
        mainDoorPosition += max(-step, min(step, target - mainDoorPosition))
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

        // The monitor dies and the shutter rolls up on its own. Whoever was on the other side of
        // it is now simply on their way out.
        power = 0
        powerOut = true
        tabletUp = false
        mainDoorClosed = false
        blackoutFor = 0
        announce("POWER OUT", subtitle: "The shutter is going up", duration: 3)
        host.minigamePlayEffect(path: "/media/fail.mp3", volume: 0.5)
        host.minigamePlayEffect(path: "/media/violin.mp3", volume: 0.4)
        onPresentationChanged?()
    }

    /// In the dark there is nothing to do but hope the bell goes first. Ten seconds, and then
    /// whoever was closest to the door walks out of it.
    private func stepBlackout(dt: Double) {
        guard powerOut, phase == .onDuty else { return }
        blackoutFor += dt
        guard blackoutFor >= Tuning.blackoutGrace else { return }
        let escapers = kids.indices.filter { !kids[$0].distractor }
        let index = escapers.max(by: { kids[$0].stage < kids[$1].stage }) ?? 0
        escaped(index)
    }

    // MARK: - One child

    private func stepKid(_ index: Int, dt: Double) {
        // Already taken the last step: the seven seconds, or Barry's way in.
        if kids[index].isAtEnd {
            if kids[index].distractor {
                letBarryIn(index)
            } else {
                stepKidAtDoor(index, dt: dt)
            }
            return
        }
        guard !kids[index].isThrough else { return }

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
    /// moves — which means the only thing that holds him back is checking the playground, and the
    /// only cost of checking the playground is the power it burns.
    private func stepSprinter(_ index: Int, dt: Double) {
        guard kids[index].aggression > 0 else { return }
        if isWatched(kids[index].room) {
            // Watching him does not just pause him, it winds him back down — slowly.
            kids[index].charge = max(0, kids[index].charge - dt * 0.7)
            return
        }
        kids[index].charge += dt
        guard kids[index].charge >= Self.sprintChargeByNight[night - 1] else { return }
        kids[index].charge = 0
        advance(index)
        // Footsteps, so his one warning is a sound rather than nothing at all.
        host.minigamePlayEffect(path: "/media/walking.mp3", volume: 0.5, rate: 1.4)
    }

    private func advance(_ index: Int) {
        kids[index].stage += 1
        if kids[index].isAtEnd, !kids[index].distractor {
            kids[index].blockedFor = 0
            kids[index].atDoorFor = 0
            // **The one warning you always get.** A bang on the front doors and a banner: you are
            // told somebody is there, and never told how long you have unless you look at CAM 7.
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.45, rate: 0.75)
            announce("SOMEBODY IS AT THE MAIN DOOR", subtitle: "Shut it", duration: 2.2)
        }
        onPresentationChanged?()
    }

    /// **The seven seconds.** From here it is only about whether the shutter comes down.
    private func stepKidAtDoor(_ index: Int, dt: Double) {
        if doorBlocks {
            kids[index].atDoorFor = 0
            kids[index].blockedFor += dt
            guard kids[index].blockedFor >= Tuning.doorGiveUp else { return }
            // Gave up. A bang on the shutter, and back down the school — that is what the door
            // actually buys you: not safety, distance.
            let name = kids[index].name
            kids[index].blockedFor = 0
            kids[index].stage = max(0, kids[index].route.count - 1 - Tuning.retreatRooms)
            kids[index].timer = Tuning.moveInterval
            kids[index].charge = 0
            host.minigamePlayEffect(path: "/media/buzzer.mp3", volume: 0.3, rate: 1.6)
            announce("BANG!", subtitle: "\(name) gave up on the shutter", duration: 1.8)
            onPresentationChanged?()
            return
        }

        kids[index].blockedFor = 0
        kids[index].atDoorFor += dt
        guard kids[index].atDoorFor >= Tuning.exitWait else { return }
        kids[index].stage += 1
        escaped(index)
    }

    /// Whether the monitor is up and pointed at this room. A child who has stepped up to the
    /// front doors is past the point where being watched stops them.
    private func isWatched(_ room: Room?) -> Bool {
        guard tabletUp, !camerasBroken, let room else { return false }
        return room == currentCam
    }

    /// **Barry gets in, and the night carries on.** He goes straight back to the start of his own
    /// route afterwards, so he can do it again — which he will.
    private func letBarryIn(_ index: Int) {
        guard barryFor <= 0 else { return }
        barryFor = Tuning.barryVisit
        barryIndex = index
        kids[index].stage = 0
        kids[index].timer = Tuning.moveInterval * 2
        tabletUp = false
        Log.world("[FiveNights] Balloon Barry is in — no cameras for \(Int(Tuning.barryVisit)) s")
        host.minigamePlayEffect(path: "/media/laugh.mp3", volume: 0.55)
        announce("BALLOON BARRY IS IN", subtitle: "He has pulled the camera fuse", duration: 2.4)
        onPresentationChanged?()
    }

    /// His fifteen seconds, and the laugh every few of them so you cannot forget he is there.
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
        announce("The cameras are back", duration: 1.4)
        onPresentationChanged?()
    }

    // MARK: - Ending a night

    private func escaped(_ index: Int) {
        guard phase == .onDuty else { return }
        phase = .escaped
        escapee = kids[index]
        barryFor = 0
        barryIndex = nil
        Log.world("[FiveNights] Night \(night): \(kids[index].name) got out at \(clockText)")
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

    /// **Nothing in this game hurts anybody**, and the words on screen are where that is decided.
    /// A child who reaches the front door has not caught you — they have got out, and the night
    /// is lost because the school is one pupil short in the morning.
    var endTitle: String {
        switch phase {
        case .survived: return night >= Tuning.nights ? "6 AM — BADGE!" : "6 AM"
        case .escaped: return powerOut ? "Lights out" : "One got out!"
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
        case .escaped:
            let name = escapee?.name ?? "Somebody"
            var lines = powerOut
                ? ["The power died at \(clockText), the shutter went up, and \(name) strolled out."]
                : ["\(name) got through the main door at \(clockText) and legged it home."]
            lines.append("One pupil short in the morning. Try night \(night) again.")
            return lines.joined(separator: "\n")
        case .onDuty:
            return ""
        }
    }

    var backgroundColor: String? { FiveNightsSchool.nightHex }

    // MARK: - Scene

    /// Only what you could actually see is drawn: whoever is in the room the monitor is pointed
    /// at, Barry when he is sitting in your office, and — once — the one who got out.
    var sceneCharacters: [MinigameCharacter] {
        if phase == .escaped, var kid = escapee {
            kid.character.x = FiveNightsSchool.exitSpot.x
            kid.character.y = FiveNightsSchool.exitSpot.y
            kid.character.rotation = 270
            return [MinigameCharacter(character: kid.character, gait: .still)]
        }

        var out: [MinigameCharacter] = []
        for (index, kid) in kids.enumerated() {
            var character = kid.character
            // Barry, in the office, in plain sight — the only child you ever see without the
            // monitor, because being seen is the entire point of him.
            if index == barryIndex, barryFor > 0 {
                character.x = FiveNightsSchool.barryPerch.x
                character.y = FiveNightsSchool.barryPerch.y
                character.rotation = 90
                out.append(MinigameCharacter(character: character, gait: .still))
                continue
            }
            guard tabletUp, !camerasBroken else { continue }

            if kid.isAtEnd, !kid.distractor {
                // At the front doors, facing them — visible on CAM 7 and nowhere else.
                guard currentCam == .mainEntrance else { continue }
                character.x = FiveNightsSchool.exitSpot.x
                character.y = FiveNightsSchool.exitSpot.y
                character.rotation = 270
            } else if let room = kid.room, room == currentCam {
                let spot = FiveNightsSchool.slot(room, index: index)
                character.x = spot.x
                character.y = spot.y
                character.rotation = 90
            } else {
                continue
            }
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
        FiveNightsSchool.building + FiveNightsSchool.mainDoor(closed: mainDoorPosition)
    }

    // MARK: - Camera

    /// Three shots, and it cuts between them rather than panning: the office, whichever feed is
    /// up, and — once — the one who got out, framed in the doorway they went through.
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
        case .escaped:
            // Right in their face, on their way out of the door.
            focusX = FiveNightsSchool.exitSpot.x
            focusY = FiveNightsSchool.exitSpot.y
            width = 2.4
            pitch = 1.30
        case .onDuty, .survived:
            if tabletUp, !camerasBroken {
                let view = FiveNightsSchool.view(of: currentCam)
                focusX = view.x
                focusY = view.y
                width = view.widthMetres
                // The corridor and the entrance hall are long and thin; a little more tip shows
                // the length of them, and the front doors at the end.
                pitch = currentCam == .westCorridor || currentCam == .mainEntrance ? 1.10 : 0.98
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
