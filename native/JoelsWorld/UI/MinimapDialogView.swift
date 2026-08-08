import UIKit

/// `#minimap-dialog`. The image is `/minimaps/<mapId>.png` and the red dot is the player's
/// position as a percentage of the map, with 0,0 at the centre (`ui.js:365-387`).
final class MinimapDialogView: UIView {
    var onClose: (() -> Void)?

    private(set) var isOpen = false

    private let wrapper = UIView()
    private let imageView = UIImageView()
    private let dot = UIView()
    private let closeButton = Theme.closeButton()
    private var mapId: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = Theme.overlayScrim
        isHidden = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        addGestureRecognizer(tap)

        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.backgroundColor = Theme.glassTint
        wrapper.layer.cornerRadius = 12
        wrapper.layer.borderWidth = 1
        wrapper.layer.borderColor = Theme.glassBorder.cgColor
        wrapper.clipsToBounds = true
        addSubview(wrapper)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 0.9
        wrapper.addSubview(imageView)

        dot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        dot.backgroundColor = Theme.danger
        dot.layer.cornerRadius = 6
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.shadowColor = Theme.danger.cgColor
        dot.layer.shadowOpacity = 1
        dot.layer.shadowRadius = 8
        dot.layer.shadowOffset = .zero
        dot.isHidden = true
        wrapper.addSubview(dot)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            wrapper.centerXAnchor.constraint(equalTo: centerXAnchor),
            wrapper.centerYAnchor.constraint(equalTo: centerYAnchor),
            wrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 512),
            wrapper.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            wrapper.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor,
                                            constant: -80),

            imageView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            closeButton.centerXAnchor.constraint(equalTo: wrapper.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: wrapper.topAnchor),
        ])
    }

    func present(mapId: Int?) {
        isOpen = true
        isHidden = false

        guard let mapId, mapId != self.mapId else { return }
        self.mapId = mapId
        imageView.image = nil
        dot.isHidden = true
        ImageLoader.load(path: "/minimaps/\(mapId).png") { [weak self] image in
            guard let self, self.mapId == mapId else { return }
            self.imageView.image = image
            // Match the wrapper to the image so the dot's percentages land on the picture.
            if let image, image.size.height > 0 {
                self.wrapper.removeConstraints(self.wrapper.constraints.filter {
                    $0.firstAttribute == .height && $0.secondAttribute == .width
                })
                self.wrapper.heightAnchor.constraint(
                    equalTo: self.wrapper.widthAnchor,
                    multiplier: image.size.height / image.size.width).isActive = true
                self.layoutIfNeeded()
            }
        }
    }

    func dismiss() {
        isOpen = false
        isHidden = true
        onClose?()
    }

    /// `updateMinimapDot` — clamped so a player standing outside the bounds still shows on
    /// the edge rather than off the image.
    func updateDot(playerX: Double, playerY: Double, mapWidth: Double, mapHeight: Double) {
        guard isOpen, imageView.image != nil, mapWidth > 0, mapHeight > 0 else { return }

        let pctX = (playerX + mapWidth / 2) / mapWidth
        let pctY = (playerY + mapHeight / 2) / mapHeight
        let safeX = min(max(0, pctX), 1)
        let safeY = min(max(0, pctY), 1)

        dot.isHidden = false
        dot.center = CGPoint(x: wrapper.bounds.width * CGFloat(safeX),
                             y: wrapper.bounds.height * CGFloat(safeY))
    }

    @objc private func closeTapped() { dismiss() }

    @objc private func scrimTapped(_ gesture: UITapGestureRecognizer) {
        if !wrapper.frame.contains(gesture.location(in: self)) { dismiss() }
    }
}
