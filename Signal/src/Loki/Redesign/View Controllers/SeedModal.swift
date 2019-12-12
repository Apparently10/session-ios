
@objc(LKSeedModal)
final class SeedModal : Modal {
    
    private let mnemonic: String = {
        let identityManager = OWSIdentityManager.shared()
        let databaseConnection = identityManager.value(forKey: "dbConnection") as! YapDatabaseConnection
        var hexEncodedSeed: String! = databaseConnection.object(forKey: "LKLokiSeed", inCollection: OWSPrimaryStorageIdentityKeyStoreCollection) as! String?
        if hexEncodedSeed == nil {
            hexEncodedSeed = identityManager.identityKeyPair()!.hexEncodedPrivateKey // Legacy account
        }
        return Mnemonic.encode(hexEncodedString: hexEncodedSeed)
    }()
    
    // MARK: Lifecycle
    override func populateContentView() {
        // Set up title label
        let titleLabel = UILabel()
        titleLabel.textColor = Colors.text
        titleLabel.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = NSLocalizedString("Your Seed", comment: "")
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .center
        // Set up mnemonic label
        let mnemonicLabel = UILabel()
        mnemonicLabel.textColor = Colors.text
        mnemonicLabel.font = .systemFont(ofSize: Values.smallFontSize)
        mnemonicLabel.text = mnemonic
        mnemonicLabel.numberOfLines = 0
        mnemonicLabel.lineBreakMode = .byWordWrapping
        mnemonicLabel.textAlignment = .center
        // Set up explanation label
        let explanationLabel = UILabel()
        explanationLabel.textColor = Colors.text.withAlphaComponent(Values.unimportantElementOpacity)
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = NSLocalizedString("This is your personal password. It can be used to restore your account or migrate your account to a new device.", comment: "")
        explanationLabel.numberOfLines = 0
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.textAlignment = .center
        // Set up copy button
        let copyButton = UIButton()
        copyButton.set(.height, to: Values.mediumButtonHeight)
        copyButton.layer.cornerRadius = Values.modalButtonCornerRadius
        copyButton.backgroundColor = Colors.buttonBackground
        copyButton.titleLabel!.font = .systemFont(ofSize: Values.smallFontSize)
        copyButton.setTitleColor(Colors.text, for: UIControl.State.normal)
        copyButton.setTitle(NSLocalizedString("Copy", comment: ""), for: UIControl.State.normal)
        copyButton.addTarget(self, action: #selector(copySeed), for: UIControl.Event.touchUpInside)
        // Set up button stack view
        let buttonStackView = UIStackView(arrangedSubviews: [ cancelButton, copyButton ])
        buttonStackView.axis = .horizontal
        buttonStackView.spacing = Values.mediumSpacing
        buttonStackView.distribution = .fillEqually
        // Set up stack view
        let stackView = UIStackView(arrangedSubviews: [ titleLabel, mnemonicLabel, explanationLabel, buttonStackView ])
        stackView.axis = .vertical
        stackView.spacing = Values.largeSpacing
        contentView.addSubview(stackView)
        stackView.pin(.leading, to: .leading, of: contentView, withInset: Values.largeSpacing)
        stackView.pin(.top, to: .top, of: contentView, withInset: Values.largeSpacing)
        contentView.pin(.trailing, to: .trailing, of: stackView, withInset: Values.largeSpacing)
        contentView.pin(.bottom, to: .bottom, of: stackView, withInset: Values.largeSpacing)
        // Mark seed as viewed
        UserDefaults.standard.set(true, forKey: "hasViewedSeed")
        NotificationCenter.default.post(name: .seedViewed, object: nil)
    }
    
    // MARK: Interaction
    @objc private func copySeed() {
        UIPasteboard.general.string = mnemonic
        dismiss(animated: true, completion: nil)
    }
}
