import UIKit
import simd

/// On-screen thumbstick. Port of `initJoystick` in `input.js:114-223`, with the magnitude kept.
///
/// The knob follows the touch out to `maxRadius`. **How far out it is pushed is the speed** —
/// the stick reports a vector, not a switch, and `GameState` scales the demanded speed by its
/// length. Past `runFraction` of the way over the character is running rather than walking, and
/// the ring drawn at that radius is where the player can see the boundary.
///
/// Before this, anything past the dead zone was the same flat-out run and the only way to move
/// slowly was to keep letting go, because speed was decided by a 2.5-second hold-to-run timer
/// rather than by the finger.
final class JoystickView: UIView {
    private let knob = UIView()
    private let runRing = CAShapeLayer()

    /// Full deflection, in points from the centre.
    private let maxRadius: CGFloat = 40
    /// Inside this the stick reads as centred. Small, because every point of it is speed the
    /// player cannot ask for.
    private let deadZone: CGFloat = 5
    /// The slowest the character will move once the stick is off centre at all. Without a floor
    /// the first few points of travel are a crawl nobody wants and everybody passes through.
    private let minThrottle: Double = 0.28
    /// Where the walk becomes a run, as a fraction of full deflection. Matches
    /// `LocomotionProfile.runThreshold`, which is what actually decides the gait.
    private let runFraction: Double = 0.55

    private var activeTouch: UITouch?

    private(set) var state = InputState()

    /// 0…1, for the knob's own appearance. `state.throttle` is the same number; this is kept
    /// separately so `layoutSubviews` can restyle without going through the input struct.
    private var throttle: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 2

        // The run boundary, so "how hard do I have to push to sprint?" is answerable by looking.
        runRing.fillColor = UIColor.clear.cgColor
        runRing.strokeColor = UIColor.white.withAlphaComponent(0.22).cgColor
        runRing.lineWidth = 1
        runRing.lineDashPattern = [3, 4]
        layer.addSublayer(runRing)

        knob.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringRadius = maxRadius * CGFloat(runFraction)
        runRing.path = UIBezierPath(arcCenter: centre,
                                    radius: ringRadius,
                                    startAngle: 0,
                                    endAngle: .pi * 2,
                                    clockwise: true).cgPath

        let knobSize: CGFloat = 52
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        if activeTouch == nil {
            knob.center = centre
        }
    }

    // Generous hit area so the stick is usable near the screen edge.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -30, dy: -30).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        update(with: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        update(with: active)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        reset()
    }

    private func update(with touch: UITouch) {
        let location = touch.location(in: self)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        let dx = location.x - center.x
        let dy = location.y - center.y
        let reach = min(maxRadius, hypot(dx, dy))
        let angle = atan2(dy, dx)

        knob.center = CGPoint(x: center.x + reach * cos(angle),
                              y: center.y + reach * sin(angle))

        if reach > deadZone {
            // The travel between the dead zone and the rim is mapped onto `minThrottle…1`, so
            // the whole of the usable range is a speed the player would actually choose.
            let fraction = Double((reach - deadZone) / (maxRadius - deadZone))
            throttle = minThrottle + (1 - minThrottle) * fraction
            // UIKit's Y axis points down, matching the game's world convention exactly, so the
            // touch offset *is* the world-space direction with no sign to flip.
            state.move = SIMD2(Double(cos(angle)) * throttle, Double(sin(angle)) * throttle)
        } else {
            throttle = 0
            state.move = .zero
        }
        restyleKnob()
    }

    private func reset() {
        activeTouch = nil
        throttle = 0
        state.move = .zero
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        restyleKnob()
    }

    /// The knob brightens with the throttle and fills in once the character is running, so the
    /// speed being asked for is visible without watching the legs.
    private func restyleKnob() {
        let running = throttle > runFraction
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.45 + 0.35 * CGFloat(throttle))
        knob.layer.borderWidth = running ? 2 : 0
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    }
}
