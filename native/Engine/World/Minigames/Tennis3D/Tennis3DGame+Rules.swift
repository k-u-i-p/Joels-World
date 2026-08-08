import Foundation

/// The rules: what a bounce means, who won the point, and what the scoreboard says.
///
/// The 2D game had no rules layer — the outcomes were scattered through the ball's physics, so
/// "was that in?" and "how does the ball bounce?" were the same function. Here every bounce
/// arrives at `onBounce()` and is turned into exactly one of: nothing happened, a fault, a let,
/// or a point to somebody. Nothing else in the game decides a point.
extension Tennis3DGame {

    /// Points, games, and the words for them.
    struct MatchScore {
        var playerPoints = 0
        var npcPoints = 0
        var playerGames = 0
        var npcGames = 0

        /// The scoreboard line for each side. Deuce and advantage are handled the way tennis
        /// handles them, which is to say oddly.
        var text: (player: String, npc: String) {
            let names = ["Love", "15", "30", "40"]

            if playerPoints >= 3 && npcPoints >= 3 {
                if playerPoints == npcPoints { return ("Deuce", "Deuce") }
                return playerPoints > npcPoints ? ("Ad", "—") : ("—", "Ad")
            }
            let player = playerPoints < names.count ? names[playerPoints] : "40"
            let npc = npcPoints < names.count ? names[npcPoints] : "40"
            return (player, npc)
        }

        /// Who, if anyone, has just won the game.
        var gameWinner: Bool? {
            if playerPoints >= 4 && playerPoints - npcPoints >= 2 { return true }
            if npcPoints >= 4 && npcPoints - playerPoints >= 2 { return false }
            return nil
        }
    }

    // MARK: - Bounces

    /// Called for every bounce, from the ball's own integrator.
    func onBounce() {
        let metre = Tennis3DCourt.unitsPerMetre
        trace(String(format: "bounce %d at (%.1f, %.1f)m — %@ to play, %@ %.1fm from it",
                     ball.bounces, ball.x / metre, ball.y / metre,
                     ball.lastHitByPlayer == true ? opponentName : "you",
                     ball.lastHitByPlayer == true ? opponentName : "you",
                     (ball.lastHitByPlayer == true
                      ? hypot(ball.x - npc.locomotion.x, ball.y - npc.locomotion.y)
                      : hypot(ball.x - player.locomotion.x, ball.y - player.locomotion.y)) / metre))

        switch phase {
        case .toss:
            // The toss came back down without being struck. In a real match you would catch it;
            // here, letting it land costs you a serve.
            callFault(reason: "MISSED THE TOSS")

        case .rally:
            if isServeInFlight {
                judgeServeBounce()
            } else {
                judgeRallyBounce()
            }

        default:
            break
        }
    }

    private func judgeServeBounce() {
        guard ball.bounces == 1 else {
            // A serve nobody touched has bounced twice: the receiver missed it entirely.
            if ball.bounces >= 2 { awardPoint(toPlayer: serverIsPlayer, reason: "ACE") }
            return
        }

        let box = Tennis3DCourt.serviceBox(receiverHalf: receiver.half, deuceCourt: deuceCourt)
        let radius = Tennis3DCourt.ballRadius
        let landedIn = ball.x >= box.minX - radius && ball.x <= box.maxX + radius
            && ball.y >= min(box.minY, box.maxY) - radius
            && ball.y <= max(box.minY, box.maxY) + radius

        if ball.clippedNet {
            // Clipped the cord: in the box is a let and gets replayed, out of it is a fault.
            if landedIn { callLet() } else { callFault(reason: "FAULT") }
            return
        }

        if landedIn {
            isServeInFlight = false      // The rally is open.
        } else {
            callFault(reason: "FAULT")
        }
    }

    private func judgeRallyBounce() {
        guard let hitByPlayer = ball.lastHitByPlayer else { return }
        // A shot is aimed into the other half; that is the only half it may land in.
        let legalHalf: Double = hitByPlayer ? -1 : 1

        if ball.bounces >= 2 {
            // Bounced twice on the receiving side — the shot was good and nobody got to it.
            awardPoint(toPlayer: hitByPlayer, reason: hitByPlayer ? "WINNER" : "POINT")
            return
        }

        if !Tennis3DCourt.isInCourt(x: ball.x, y: ball.y, half: legalHalf) {
            let intoNet = ball.clippedNet
            awardPoint(toPlayer: !hitByPlayer,
                       reason: intoNet ? "INTO THE NET" : "OUT")
        }
    }

    /// The ball has left the court without settling anything — hit flat out over the fence.
    func resolveDeadBall() {
        guard phase == .rally else { return }
        guard let hitByPlayer = ball.lastHitByPlayer else { return }

        if isServeInFlight {
            callFault(reason: "FAULT")
        } else {
            awardPoint(toPlayer: !hitByPlayer, reason: "LONG")
        }
    }

    // MARK: - Outcomes

    private func callFault(reason: String) {
        faults += 1
        ball.inFlight = false
        trace("fault \(faults) — \(reason)")

        if faults >= 2 {
            awardPoint(toPlayer: !serverIsPlayer, reason: "DOUBLE FAULT")
            return
        }

        serveIsReplay = true
        endPoint(banner: reason, subtitle: "Second serve", pause: 1.5)
    }

    private func callLet() {
        ball.inFlight = false
        serveIsReplay = true
        endPoint(banner: "LET", subtitle: "Play it again", pause: 1.4)
    }

    /// The watchdog's escape hatch: the ball has stopped meaning anything and nobody has won
    /// the point. Replayed rather than awarded, because a watchdog firing is a bug in the
    /// simulation and a bug should never quietly hand somebody a point.
    func abandonPoint() {
        guard phase == .rally || phase == .toss else { return }
        ball.inFlight = false
        ball.heldByServer = false
        // Not a fault: the serve that started this is not the thing that went wrong.
        serveIsReplay = true
        isServeInFlight = false
        endPoint(banner: "LET", subtitle: "Play it again", pause: 1.4)
    }

    /// The only place a point is ever scored.
    func awardPoint(toPlayer: Bool, reason: String) {
        guard phase == .rally || phase == .toss else { return }

        ball.inFlight = false
        faults = 0
        serveIsReplay = false
        isServeInFlight = false

        if toPlayer { score.playerPoints += 1 } else { score.npcPoints += 1 }
        trace("POINT to \(toPlayer ? "you" : opponentName) — \(reason) "
              + "(\(score.text.player)–\(score.text.npc), games "
              + "\(score.playerGames)–\(score.npcGames))")

        guard let gameWinner = score.gameWinner else {
            let line = score.text
            endPoint(banner: reason,
                     subtitle: "\(line.player) — \(line.npc)",
                     pause: 2.0)
            if reason == "WINNER" || score.playerPoints + score.npcPoints >= 6 {
                host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.55)
            }
            return
        }

        // Game over: reset the points, hand the serve to the other player.
        score.playerPoints = 0
        score.npcPoints = 0
        if gameWinner { score.playerGames += 1 } else { score.npcGames += 1 }
        serverIsPlayer.toggle()

        if score.playerGames >= Tuning.gamesToWinMatch {
            winMatch()
            return
        }
        if score.npcGames >= Tuning.gamesToWinMatch {
            loseMatch()
            return
        }

        endPoint(banner: gameWinner ? "GAME — YOU" : "GAME — \(opponentName)",
                 subtitle: "Games \(score.playerGames) — \(score.npcGames)",
                 pause: 2.6)
        host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.8)
    }

    private func winMatch() {
        phase = .matchOver
        phaseTimer = 0
        announce("GAME, SET AND MATCH", subtitle: "You win \(score.playerGames)—\(score.npcGames)",
                 duration: 6)
        host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 1.0)
        host.minigameAwardBadge("tennis")
        onPresentationChanged?()
    }

    private func loseMatch() {
        phase = .matchOver
        phaseTimer = 0
        announce("MATCH TO \(opponentName.uppercased())",
                 subtitle: "\(score.npcGames)—\(score.playerGames). Have another go?",
                 duration: 6)
        host.minigamePlayEffect(path: "/media/fail.mp3", volume: 0.7)
        onPresentationChanged?()
    }

    var opponentName: String { npc.appearance.name ?? "Alex" }

    private func endPoint(banner: String, subtitle: String?, pause: Double) {
        phase = .pointOver
        phaseTimer = pause
        player.swing = SwingState()
        npc.swing = SwingState()
        player.moveTarget = nil
        npc.moveTarget = nil
        announce(banner, subtitle: subtitle, duration: pause)
        onPresentationChanged?()
    }

    // MARK: - Between points

    /// Sets up whatever comes next: a second serve, or a fresh point from the other court.
    func setUpNextPoint() {
        guard phase == .pointOver else { return }

        if !serveIsReplay {
            // The court alternates every point, starting on the deuce side.
            deuceCourt = (score.playerPoints + score.npcPoints) % 2 == 0
            // Re-seed from the scoreline, so a given point in a given game always plays out
            // the same way. Two matches that reach 30–15 in the second game see the same serve.
            random.reseed(seed(forGame: score.playerGames &+ score.npcGames))
        }
        serveIsReplay = false
        isServeInFlight = false

        ball.parkOffCourt()
        moveToServeMarks()
        onPresentationChanged?()
    }

    private func seed(forGame gameNumber: Int) -> UInt64 {
        var value: UInt64 = 0x5EED
        value = value &* 31 &+ UInt64(bitPattern: Int64(gameNumber))
        value = value &* 31 &+ UInt64(bitPattern: Int64(score.playerPoints))
        value = value &* 31 &+ UInt64(bitPattern: Int64(score.npcPoints))
        value = value &* 31 &+ (serverIsPlayer ? 1 : 0)
        return value
    }

    /// Starts a fresh match without leaving the court. The "play again" button on the
    /// match-over panel.
    func restartMatch() {
        score = MatchScore()
        faults = 0
        serveIsReplay = false
        isServeInFlight = false
        serverIsPlayer = true
        deuceCourt = true
        random.reseed(0xA11CE)
        ball.parkOffCourt()
        announce("NEW MATCH", subtitle: "First to \(Tuning.gamesToWinMatch) games", duration: 2.0)
        moveToServeMarks()
        onPresentationChanged?()
    }

    // MARK: - Scoreboard

    /// Everything the HUD needs, in one read.
    struct Scoreboard {
        var playerPoints: String
        var npcPoints: String
        var playerGames: Int
        var npcGames: Int
        var opponentName: String
        var serverIsPlayer: Bool
        var isMatchOver: Bool
        var playerWonMatch: Bool
    }

    var scoreboard: Scoreboard {
        let line = score.text
        return Scoreboard(playerPoints: line.player,
                          npcPoints: line.npc,
                          playerGames: score.playerGames,
                          npcGames: score.npcGames,
                          opponentName: opponentName,
                          serverIsPlayer: serverIsPlayer,
                          isMatchOver: phase == .matchOver,
                          playerWonMatch: score.playerGames >= Tuning.gamesToWinMatch)
    }
}
