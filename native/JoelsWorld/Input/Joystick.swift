import UIKit

/// On-screen thumbstick. Port of `initJoystick` in `input.js:114-223`.
///
/// The knob follows the touch out to `maxRadius`; anything past a small dead zone counts as
/// movement and sets the player's heading directly.
final class JoystickView: UIView {
    private let knob = UIView()
    private let maxRadius: CGFloat = 40
    private let deadZone: CGFloat = 10

    private var activeTouch: UITouch?

    private(set) var state = InputState()

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

        knob.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2

        let knobSize: CGFloat = 52
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        if activeTouch == nil {
            knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
        let distance = min(maxRadius, hypot(dx, dy))
        let angle = atan2(dy, dx)

        knob.center = CGPoint(x: center.x + distance * cos(angle),
                              y: center.y + distance * sin(angle))

        if distance > deadZone {
            state.isMoving = true
            // UIKit's Y axis points down, matching the game's world convention exactly.
            state.angleDegrees = Double(angle) * 180 / .pi
        } else {
            state.isMoving = false
        }
    }

    private func reset() {
        activeTouch = nil
        state.isMoving = false
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
