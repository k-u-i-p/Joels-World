import UIKit

/// `#ui-buttons-container` — the row of round buttons in the bottom-right corner.
///
/// The web build gives the map button a bitmap (`icons/minimap.png`, 340 KB); the native one
/// uses the system map glyph so nothing has to be fetched to draw the HUD.
final class ButtonBarView: UIView {
    var onMap: (() -> Void)?
    var onBadges: (() -> Void)?
    var onEmotes: (() -> Void)?
    var onHelp: (() -> Void)?
    /// `#exit-button` — the 🏃 that leaves a minigame (`index.html:232`).
    var onExit: (() -> Void)?

    private let stack = UIStackView()
    private var mapButton: UIButton!
    private var exitButton: UIButton!
    private var badgesButton: UIButton!
    private var emotesButton: UIButton!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 15
        stack.alignment = .center
        addSubview(stack)

        let map = circleButton(symbol: "map.fill")
        map.addTarget(self, action: #selector(mapTapped), for: .touchUpInside)
        mapButton = map

        let exit = circleButton(title: "🏃")
        exit.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        exit.isHidden = true
        exitButton = exit

        let badges = circleButton(title: "🏅")
        badges.addTarget(self, action: #selector(badgesTapped), for: .touchUpInside)
        badgesButton = badges

        let emotes = circleButton(title: "☺️")
        emotes.addTarget(self, action: #selector(emotesTapped), for: .touchUpInside)
        emotesButton = emotes

        let help = circleButton(title: "?")
        help.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        help.addTarget(self, action: #selector(helpTapped), for: .touchUpInside)

        for button in [map, exit, badges, emotes, help] { stack.addArrangedSubview(button) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func circleButton(title: String? = nil, symbol: String? = nil) -> UIButton {
        let button = Theme.makePlainButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        if let title {
            button.setEmojiTitle(title, font: .systemFont(ofSize: 24), color: .white)
        }
        if let symbol {
            button.setImage(UIImage(systemName: symbol,
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 20,
                                                                                   weight: .semibold)),
                            for: .normal)
        }
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = Theme.primary
        button.layer.cornerRadius = 22
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.4
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.alpha = 0.9
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    /// A minigame swaps the map button for the exit button, and puts the badges and emotes
    /// buttons away until it is over.
    ///
    /// The swap is what `tennis.js:679-683` does to the same row. Hiding the other two is not,
    /// and it is here because of where this row sits: five 44-point circles across the
    /// bottom-right corner, which in the 3D tennis game is **exactly where the near player stands
    /// when a deep ball has pushed them back onto the fence**. They are on top of the character
    /// and they eat the first centimetre of any drag that starts there — which is the drag you
    /// most need, because you are in trouble. Neither button does anything a minigame can use:
    /// the character on court is the game's, not the world's, so an emote goes nowhere, and the
    /// badge you are playing for is one tap away the moment you leave.
    func setMinigameMode(_ active: Bool) {
        mapButton.isHidden = active
        exitButton.isHidden = !active
        badgesButton.isHidden = active
        emotesButton.isHidden = active
        // The row moves to the top-right corner for a minigame (`setButtonBarOutOfPlay`), where a
        // horizontal pair of circles runs into the right-hand end of the scoreboard. Stacked, the
        // two survivors are one button wide and clear it.
        stack.axis = active ? .vertical : .horizontal
    }

    @objc private func mapTapped() { onMap?() }
    @objc private func exitTapped() { onExit?() }
    @objc private func badgesTapped() { onBadges?() }
    @objc private func emotesTapped() { onEmotes?() }
    @objc private func helpTapped() { onHelp?() }
}
