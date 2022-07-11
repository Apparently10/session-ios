// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import QuartzCore
import GRDB
import DifferenceKit
import SessionUIKit
import SignalUtilitiesKit

public class DocumentTileViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    /// This should be larger than one screen size so we don't have to call it multiple times in rapid succession, but not
    /// so large that loading get's really chopping
    static let itemPageSize: Int = Int(11 * itemsPerPortraitRow)
    static let itemsPerPortraitRow: CGFloat = 4
    static let interItemSpacing: CGFloat = 2
    static let footerBarHeight: CGFloat = 40
    static let loadMoreHeaderHeight: CGFloat = 100
    
    private let viewModel: MediaGalleryViewModel
    private var hasLoadedInitialData: Bool = false
    private var didFinishInitialLayout: Bool = false
    private var isAutoLoadingNextPage: Bool = false
    private var currentTargetOffset: CGPoint?
    
    // MARK: - Initialization

    init(viewModel: MediaGalleryViewModel) {
        self.viewModel = viewModel
        Storage.shared.addObserver(viewModel.pagedDataObserver)

        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }
    
    lazy var tableView: UITableView = {
        let result = UITableView(frame: .zero, style: .grouped)
        result.backgroundColor = Colors.navigationBarBackground
        result.separatorStyle = .none
        result.showsVerticalScrollIndicator = false
        result.register(view: DocumentCell.self)
        result.delegate = self
        result.dataSource = self
        // Feels a bit weird to have content smashed all the way to the bottom edge.
        result.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        
        return result
    }()
    
    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        // Add a custom back button if this is the only view controller
        if self.navigationController?.viewControllers.first == self {
            let backButton = OWSViewController.createOWSBackButton(withTarget: self, selector: #selector(didPressDismissButton))
            self.navigationItem.leftBarButtonItem = backButton
        }
        
        ViewControllerUtilities.setUpDefaultSessionStyle(
            for: self,
            title: MediaStrings.document,
            hasCustomBackButton: false
        )

        view.addSubview(self.tableView)
        tableView.autoPin(toEdgesOf: view)
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.didFinishInitialLayout = true
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        startObservingChanges()
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        stopObservingChanges()
    }
    
    // MARK: - Updating
    
    private func performInitialScrollIfNeeded() {
        // Ensure this hasn't run before and that we have data (The 'galleryData' will always
        // contain something as the 'empty' state is a section within 'galleryData')
        guard !self.didFinishInitialLayout && self.hasLoadedInitialData else { return }
        
        // If we have a focused item then we want to scroll to it
        guard let focusedIndexPath: IndexPath = self.viewModel.focusedIndexPath else { return }
        
        Logger.debug("scrolling to focused item at indexPath: \(focusedIndexPath)")
        self.view.layoutIfNeeded()
        self.tableView.scrollToRow(at: focusedIndexPath, at: .middle, animated: false)
        
        // Now that the data has loaded we need to check if either of the "load more" sections are
        // visible and trigger them if so
        //
        // Note: We do it this way as we want to trigger the load behaviour for the first section
        // if it has one before trying to trigger the load behaviour for the last section
        self.autoLoadNextPageIfNeeded()
    }
    
    private func autoLoadNextPageIfNeeded() {
        guard !self.isAutoLoadingNextPage else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sortedVisibleIndexPaths: [IndexPath] = (self?.tableView.indexPathsForVisibleRows ?? []).sorted()
            
            for headerIndexPath in sortedVisibleIndexPaths {
                let section: MediaGalleryViewModel.SectionModel? = self?.viewModel.galleryData[safe: headerIndexPath.section]
                
                switch section?.model {
                    case .loadNewer, .loadOlder:
                        // Attachments are loaded in descending order so 'loadOlder' actually corresponds with
                        // 'pageAfter' in this case
                        self?.viewModel.pagedDataObserver?.load(section?.model == .loadOlder ?
                            .pageAfter :
                            .pageBefore
                        )
                        return
                        
                    default: continue
                }
            }
        }
    }
    
    private func startObservingChanges() {
        // Start observing for data changes (will callback on the main thread)
        self.viewModel.onGalleryChange = { [weak self] updatedGalleryData in
            self?.handleUpdates(updatedGalleryData)
        }
    }
    
    private func stopObservingChanges() {
        // Note: The 'pagedDataObserver' will continue to get changes but
        // we don't want to trigger any UI updates
        self.viewModel.onGalleryChange = nil
    }
    
    private func handleUpdates(_ updatedGalleryData: [MediaGalleryViewModel.SectionModel]) {
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialData else {
            self.hasLoadedInitialData = true
            self.viewModel.updateGalleryData(updatedGalleryData)
            
            UIView.performWithoutAnimation {
                self.tableView.reloadData()
                self.performInitialScrollIfNeeded()
            }
            return
        }
    }
    
    // MARK: - Interactions
    
    @objc public func didPressDismissButton() {
        let presentedNavController: UINavigationController? = (self.presentingViewController as? UINavigationController)
        let mediaPageViewController: MediaPageViewController? = (
            (presentedNavController?.viewControllers.last as? MediaPageViewController) ??
            (self.presentingViewController as? MediaPageViewController)
        )
        
        // If the album was presented from a 'MediaPageViewController' and it has no more data (ie.
        // all album items had been deleted) then dismiss to the screen before that one
        guard mediaPageViewController?.viewModel.albumData.isEmpty != true else {
            presentedNavController?.presentingViewController?.dismiss(animated: true, completion: nil)
            return
        }
        
        dismiss(animated: true, completion: nil)
    }
    
    // MARK: - UITableViewDataSource
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return self.viewModel.galleryData.count
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.viewModel.galleryData[section].elements.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: DocumentCell = tableView.dequeue(type: DocumentCell.self, for: indexPath)
        cell.update(with: self.viewModel.galleryData[indexPath.section].elements[indexPath.row])
        return cell
    }
    
    // MARK: - UITableViewDelegate
    
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: MediaGalleryViewModel.SectionModel = self.viewModel.galleryData[section]
        
        switch section.model {
            case .emptyGallery, .loadOlder, .loadNewer:
            let headerView: DocumentStaticHeaderView = DocumentStaticHeaderView()
            headerView.configure(
                title: {
                    switch section.model {
                        case .emptyGallery: return "DOCUMENT_TILES_EMPTY_DOCUMENT".localized()
                        case .loadOlder: return "DOCUMENT_TILES_LOADING_OLDER_LABEL".localized()
                        case .loadNewer: return "DOCUMENT_TILES_LOADING_MORE_RECENT_LABEL".localized()
                        case .galleryMonth: return ""   // Impossible case
                    }
                }()
            )
            return headerView
                
            case .galleryMonth(let date):
                let headerView: DocumentSectionHeaderView = DocumentSectionHeaderView()
                headerView.configure(title: date.localizedString)
                return headerView
        }
    }
    
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section: MediaGalleryViewModel.SectionModel = self.viewModel.galleryData[section]
        
        switch section.model {
            case .emptyGallery, .loadOlder, .loadNewer:
                return MediaTileViewController.loadMoreHeaderHeight
            
            case .galleryMonth:
                return 50
        }
    }
}

class DocumentCell: UITableViewCell {

    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        setUpViewHierarchy()
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        setUpViewHierarchy()
        setupLayout()
    }
    
    // MARK: - UI
    
    private static let iconImageViewSize: CGSize = CGSize(width: 31, height: 40)
    
    private let iconImageView: UIImageView = {
        let result: UIImageView = UIImageView(image: #imageLiteral(resourceName: "File").withRenderingMode(.alwaysTemplate))
        result.translatesAutoresizingMaskIntoConstraints = false
        result.tintColor = Colors.text
        
        return result
    }()
    
    private let titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.textColor = Colors.text
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private let detailLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.textColor = Colors.text
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private func setUpViewHierarchy() {
        backgroundColor = Colors.cellBackground
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = Colors.cellSelected
        
        
        contentView.addSubview(iconImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(equalToConstant: 68),
            
            iconImageView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: Values.mediumSpacing),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: Self.iconImageViewSize.width),
            iconImageView.heightAnchor.constraint(equalToConstant: Self.iconImageViewSize.height),
            
            titleLabel.leftAnchor.constraint(equalTo: iconImageView.rightAnchor, constant: Values.mediumSpacing),
            titleLabel.rightAnchor.constraint(lessThanOrEqualTo: contentView.rightAnchor, constant: -Values.mediumSpacing),
            titleLabel.topAnchor.constraint(equalTo: iconImageView.topAnchor),
            
            detailLabel.leftAnchor.constraint(equalTo: iconImageView.rightAnchor, constant: Values.mediumSpacing),
            detailLabel.rightAnchor.constraint(lessThanOrEqualTo: contentView.rightAnchor, constant: -Values.mediumSpacing),
            detailLabel.bottomAnchor.constraint(equalTo: iconImageView.bottomAnchor),
        ])
    }
    
    // MARK: - Content
    
    func update(with item: MediaGalleryViewModel.Item) {
        let attachment = item.attachment
        titleLabel.text = attachment.sourceFilename ?? "File"
        detailLabel.text = "\(OWSFormat.formatFileSize(UInt(attachment.byteCount)))"
    }
}

class DocumentSectionHeaderView: UIView {
    
    let label: UILabel

    override init(frame: CGRect) {
        label = UILabel()
        label.textColor = Colors.text

        let blurEffect = UIBlurEffect(style: .dark)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)

        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        super.init(frame: frame)

        self.backgroundColor = isLightMode ? Colors.cellBackground : UIColor.ows_black.withAlphaComponent(OWSNavigationBar.backgroundBlurMutingFactor)

        self.addSubview(blurEffectView)
        self.addSubview(label)

        blurEffectView.autoPinEdgesToSuperviewEdges()
        blurEffectView.isHidden = isLightMode
        label.autoPinEdge(toSuperviewMargin: .trailing)
        label.autoPinEdge(toSuperviewMargin: .leading)
        label.autoVCenterInSuperview()
    }

    @available(*, unavailable, message: "Unimplemented")
    required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    public func configure(title: String) {
        self.label.text = title
    }
}

class DocumentStaticHeaderView: UIView {
    
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        addSubview(label)

        label.textColor = Colors.text
        label.textAlignment = .center
        label.numberOfLines = 0
        label.autoPinEdgesToSuperviewMargins(with: UIEdgeInsets(top: 0, leading: Values.largeSpacing, bottom: 0, trailing: Values.largeSpacing))
    }

    @available(*, unavailable, message: "Unimplemented")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    public func configure(title: String) {
        self.label.text = title
    }
}
