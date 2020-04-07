
final class TextField : UITextField {
    private let usesDefaultHeight: Bool
    private let height: CGFloat
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat

    init(placeholder: String, usesDefaultHeight: Bool = true, customHeight: CGFloat? = nil, customHorizontalInset: CGFloat? = nil, customVerticalInset: CGFloat? = nil) {
        self.usesDefaultHeight = usesDefaultHeight
        self.height = customHeight ?? Values.textFieldHeight
        self.horizontalInset = customHorizontalInset ?? (isSmallScreen ? Values.mediumSpacing : Values.largeSpacing)
        self.verticalInset = customVerticalInset ?? (isSmallScreen ? Values.smallSpacing : Values.largeSpacing)
        super.init(frame: CGRect.zero)
        self.placeholder = placeholder
        setUpStyle()
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    private func setUpStyle() {
        textColor = Colors.text
        font = .systemFont(ofSize: Values.smallFontSize)
        let placeholder = NSMutableAttributedString(string: self.placeholder!)
        let placeholderColor = Colors.text.withAlphaComponent(Values.unimportantElementOpacity)
        placeholder.addAttribute(.foregroundColor, value: placeholderColor, range: NSRange(location: 0, length: placeholder.length))
        attributedPlaceholder = placeholder
        tintColor = Colors.accent
        keyboardAppearance = isLightMode ? .light : .dark
        if usesDefaultHeight {
            set(.height, to: height)
        }
        layer.borderColor = isLightMode ? Colors.text.cgColor : Colors.border.withAlphaComponent(Values.textFieldBorderOpacity).cgColor
        layer.borderWidth = Values.borderThickness
        layer.cornerRadius = Values.textFieldCornerRadius
    }
    
    override func textRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        } else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
    
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        } else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
}
