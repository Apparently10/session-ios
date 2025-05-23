// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class MentionSelectionView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let dependencies: Dependencies
    var currentUserSessionId: String?
    var currentUserBlinded15SessionId: String?
    var currentUserBlinded25SessionId: String?
    var candidates: [MentionInfo] = [] {
        didSet {
            tableView.isScrollEnabled = (candidates.count > 4)
            tableView.reloadData()
        }
    }
    
    weak var delegate: MentionSelectionViewDelegate?
    
    var contentOffset: CGPoint {
        get { tableView.contentOffset }
        set { tableView.contentOffset = newValue }
    }

    // MARK: - Components
    
    private lazy var tableView: UITableView = {
        let result: UITableView = UITableView()
        result.dataSource = self
        result.delegate = self
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.register(view: Cell.self)
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
    }
    
    @available(*, unavailable, message: "use other init(using:) instead.")
    required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUpViewHierarchy() {
        // Table view
        addSubview(tableView)
        tableView.pin(to: self)
        
        // Top separator
        let topSeparator: UIView = UIView()
        topSeparator.themeBackgroundColor = .borderSeparator
        topSeparator.set(.height, to: Values.separatorThickness)
        addSubview(topSeparator)
        topSeparator.pin(.leading, to: .leading, of: self)
        topSeparator.pin(.top, to: .top, of: self)
        topSeparator.pin(.trailing, to: .trailing, of: self)
        
        // Bottom separator
        let bottomSeparator: UIView = UIView()
        bottomSeparator.themeBackgroundColor = .borderSeparator
        bottomSeparator.set(.height, to: Values.separatorThickness)
        addSubview(bottomSeparator)
        
        bottomSeparator.pin(.leading, to: .leading, of: self)
        bottomSeparator.pin(.trailing, to: .trailing, of: self)
        bottomSeparator.pin(.bottom, to: .bottom, of: self)
    }

    // MARK: - Data
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return candidates.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: Cell = tableView.dequeue(type: Cell.self, for: indexPath)
        cell.update(
            with: candidates[indexPath.row].profile,
            threadVariant: candidates[indexPath.row].threadVariant,
            isUserModeratorOrAdmin: dependencies[singleton: .openGroupManager].isUserModeratorOrAdmin(
                publicKey: candidates[indexPath.row].profile.id,
                for: candidates[indexPath.row].openGroupRoomToken,
                on: candidates[indexPath.row].openGroupServer
            ),
            currentUserSessionId: currentUserSessionId,
            currentUserBlinded15SessionId: currentUserBlinded15SessionId,
            currentUserBlinded25SessionId: currentUserBlinded25SessionId,
            isLast: (indexPath.row == (candidates.count - 1)),
            using: dependencies
        )
        cell.accessibilityIdentifier = "Contact"
        cell.accessibilityLabel = candidates[indexPath.row].profile.displayName(
            for: candidates[indexPath.row].threadVariant
        )
        cell.isAccessibilityElement = true
        
        return cell
    }

    // MARK: - Interaction
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let mentionCandidate = candidates[indexPath.row]
        
        delegate?.handleMentionSelected(mentionCandidate, from: self)
    }
}

// MARK: - Cell

private extension MentionSelectionView {
    final class Cell: UITableViewCell {
        // MARK: - UI
        
        private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(
            size: .message,
            dataManager: nil
        )

        private lazy var displayNameLabel: UILabel = {
            let result: UILabel = UILabel()
            result.font = .systemFont(ofSize: Values.smallFontSize)
            result.themeTextColor = .textPrimary
            result.lineBreakMode = .byTruncatingTail
            
            return result
        }()

        lazy var separator: UIView = {
            let result: UIView = UIView()
            result.themeBackgroundColor = .borderSeparator
            result.set(.height, to: Values.separatorThickness)
            
            return result
        }()

        // MARK: - Initialization
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            
            setUpViewHierarchy()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            
            setUpViewHierarchy()
        }

        private func setUpViewHierarchy() {
            // Cell background color
            themeBackgroundColor = .settings_tabBackground
            
            // Highlight color
            let selectedBackgroundView = UIView()
            selectedBackgroundView.themeBackgroundColor = .highlighted(.settings_tabBackground)
            self.selectedBackgroundView = selectedBackgroundView
            
            // Main stack view
            let mainStackView = UIStackView(arrangedSubviews: [ profilePictureView, displayNameLabel ])
            mainStackView.axis = .horizontal
            mainStackView.alignment = .center
            mainStackView.spacing = Values.mediumSpacing
            mainStackView.set(.height, to: ProfilePictureView.Size.message.viewSize)
            contentView.addSubview(mainStackView)
            mainStackView.pin(.leading, to: .leading, of: contentView, withInset: Values.mediumSpacing)
            mainStackView.pin(.top, to: .top, of: contentView, withInset: Values.smallSpacing)
            contentView.pin(.trailing, to: .trailing, of: mainStackView, withInset: Values.mediumSpacing)
            contentView.pin(.bottom, to: .bottom, of: mainStackView, withInset: Values.smallSpacing)
            mainStackView.set(.width, to: UIScreen.main.bounds.width - 2 * Values.mediumSpacing)
            
            // Separator
            addSubview(separator)
            separator.pin(.leading, to: .leading, of: self)
            separator.pin(.trailing, to: .trailing, of: self)
            separator.pin(.bottom, to: .bottom, of: self)
        }

        // MARK: - Updating
        
        fileprivate func update(
            with profile: Profile,
            threadVariant: SessionThread.Variant,
            isUserModeratorOrAdmin: Bool,
            currentUserSessionId: String?,
            currentUserBlinded15SessionId: String?,
            currentUserBlinded25SessionId: String?,
            isLast: Bool,
            using dependencies: Dependencies
        ) {
            let currentUserSessionIds: Set<String> = [
                currentUserSessionId,
                currentUserBlinded15SessionId,
                currentUserBlinded25SessionId
            ].compactMap { $0 }.asSet()
            displayNameLabel.text = (currentUserSessionIds.contains(profile.id) ?
                "you".localized() :
                profile.displayName(for: threadVariant)
            )
            profilePictureView.setDataManager(dependencies[singleton: .imageDataManager])
            profilePictureView.update(
                publicKey: profile.id,
                threadVariant: .contact,    // Always show the display picture in 'contact' mode
                displayPictureFilename: nil,
                profile: profile,
                profileIcon: (isUserModeratorOrAdmin ? .crown : .none),
                using: dependencies
            )
            separator.isHidden = isLast
        }
    }
}

// MARK: - Delegate

protocol MentionSelectionViewDelegate: AnyObject {
    func handleMentionSelected(_ mention: MentionInfo, from view: MentionSelectionView)
}
