// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public class MediaAlbumView: UIStackView {
    private let items: [Attachment]
    public let itemViews: [MediaView]
    public var moreItemsView: MediaView?
    public var numItems: Int { return items.count }
    public var numVisibleItems: Int { return itemViews.count }

    private static let kSpacingPts: CGFloat = 4
    private static let kMaxItems = 3

    @available(*, unavailable, message: "use other init() instead.")
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public required init(
        items: [Attachment],
        isOutgoing: Bool,
        maxMessageWidth: CGFloat,
        using dependencies: Dependencies
    ) {
        let itemsToDisplay: [Attachment] = MediaAlbumView.itemsToDisplay(forItems: items)
        
        self.items = items
        self.itemViews = itemsToDisplay.enumerated()
            .map { index, attachment -> MediaView in
                MediaView(
                    attachment: attachment,
                    isOutgoing: isOutgoing,
                    shouldSupressControls: (
                        // If there are extra items that aren't displayed and this is the
                        // last one that will be displayed then suppress any custom controls
                        // otherwise the '+' icon will be obscured
                        itemsToDisplay.count != items.count &&
                        (index == (itemsToDisplay.count - 1))
                    ),
                    cornerRadius: VisibleMessageCell.largeCornerRadius,
                    using: dependencies
                )
            }

        super.init(frame: .zero)

        createContents(maxMessageWidth: maxMessageWidth)
    }

    private func createContents(maxMessageWidth: CGFloat) {
        let backgroundView: UIView = UIView()
        backgroundView.themeBackgroundColor = .backgroundPrimary
        addSubview(backgroundView)
        
        backgroundView.setContentHugging(to: .defaultLow)
        backgroundView.setCompressionResistance(to: .defaultLow)
        backgroundView.pin(to: backgroundView)
        
        switch itemViews.count {
            case 0: return Log.error("[MediaAlbumView] No item views.")
                
            case 1:
                // X
                guard let itemView = itemViews.first else {
                    Log.error("[MediaAlbumView] Missing item view.")
                    return
                }
                addSubview(itemView)
                itemView.pin(to: self)
                
            case 2:
                // X X
                // side-by-side.
                let imageSize = (maxMessageWidth - MediaAlbumView.kSpacingPts) / 2
                autoSet(viewSize: imageSize, ofViews: itemViews)
                for itemView in itemViews {
                    addArrangedSubview(itemView)
                }
                self.axis = .horizontal
                self.distribution = .fillEqually
                self.spacing = MediaAlbumView.kSpacingPts
            
            default:
                //   x
                // X x
                // Big on left, 2 small on right.
                let smallImageSize = (maxMessageWidth - MediaAlbumView.kSpacingPts * 2) / 3
                let bigImageSize = smallImageSize * 2 + MediaAlbumView.kSpacingPts

                guard let leftItemView = itemViews.first else {
                    Log.error("[MediaAlbumView] Missing view")
                    return
                }
                autoSet(viewSize: bigImageSize, ofViews: [leftItemView])
                addArrangedSubview(leftItemView)

                let rightViews = Array(itemViews[1..<3])
                addArrangedSubview(
                    newRow(
                        rowViews: rightViews,
                        axis: .vertical,
                        viewSize: smallImageSize
                    )
                )
                self.axis = .horizontal
                self.spacing = MediaAlbumView.kSpacingPts

                if items.count > MediaAlbumView.kMaxItems {
                    guard let lastView = rightViews.last else {
                        Log.error("[MediaAlbumView] Missing lastView")
                        return
                    }

                    moreItemsView = lastView

                    let tintView = UIView()
                    tintView.themeBackgroundColor = .messageBubble_overlay
                    lastView.addSubview(tintView)
                    tintView.pin(to: self)

                    let moreCount = max(1, items.count - MediaAlbumView.kMaxItems)
                    let moreText = "andMore"
                        .put(key: "count", value: moreCount)
                        .localized()
                    let moreLabel: UILabel = UILabel()
                    moreLabel.font = .systemFont(ofSize: 24)
                    moreLabel.text = moreText
                    moreLabel.themeTextColor = .white
                    lastView.addSubview(moreLabel)
                    moreLabel.center(in: lastView)
                }
        }

        for itemView in itemViews {
            guard moreItemsView != itemView else {
                // Don't display the caption indicator on
                // the "more" item, if any.
                continue
            }
            guard let index = itemViews.firstIndex(of: itemView) else {
                Log.error("[MediaAlbumView] Couldn't determine index of item view.")
                continue
            }
            let item = items[index]
            guard let caption = item.caption else {
                continue
            }
            guard caption.count > 0 else {
                continue
            }
            guard let icon = UIImage(named: "media_album_caption") else {
                Log.error("[MediaAlbumView] Couldn't load icon.")
                continue
            }
            let iconView = UIImageView(image: icon)
            itemView.addSubview(iconView)
            itemView.layoutMargins = .zero
            iconView.pin(.top, to: .top, of: itemView.layoutMarginsGuide, withInset: 6)
            iconView.pin(.leading, to: .leading, of: itemView.layoutMarginsGuide, withInset: 6)
        }
    }

    private func autoSet(
        viewSize: CGFloat,
        ofViews views: [MediaView]
    ) {
        for itemView in views {
            itemView.set(.width, to: viewSize)
            itemView.set(.height, to: viewSize)
        }
    }

    private func newRow(
        rowViews: [MediaView],
        axis: NSLayoutConstraint.Axis,
        viewSize: CGFloat
    ) -> UIStackView {
        autoSet(viewSize: viewSize, ofViews: rowViews)
        return newRow(rowViews: rowViews, axis: axis)
    }

    private func newRow(
        rowViews: [MediaView],
        axis: NSLayoutConstraint.Axis
    ) -> UIStackView {
        let stackView = UIStackView(arrangedSubviews: rowViews)
        stackView.axis = axis
        stackView.spacing = MediaAlbumView.kSpacingPts
        return stackView
    }

    private class func itemsToDisplay(forItems items: [Attachment]) -> [Attachment] {
        // TODO: Unless design changes, we want to display
        //       items which are still downloading and invalid
        //       items.
        let validItems = items
        guard validItems.count < kMaxItems else {
            return Array(validItems[0..<kMaxItems])
        }
        return validItems
    }

    public class func layoutSize(
        forMaxMessageWidth maxMessageWidth: CGFloat,
        items: [Attachment]
    ) -> CGSize {
        let itemCount = itemsToDisplay(forItems: items).count
        
        switch itemCount {
            case 0, 1:
                // X
                // Square
                return CGSize(width: maxMessageWidth, height: maxMessageWidth)
                
            case 2:
                // X X
                // side-by-side.
                let imageSize = (maxMessageWidth - kSpacingPts) / 2
                return CGSize(width: maxMessageWidth, height: imageSize)
                
            default:
                //   x
                // X x
                // Big on left, 2 small on right.
                let smallImageSize = (maxMessageWidth - kSpacingPts * 2) / 3
                let bigImageSize = smallImageSize * 2 + kSpacingPts
                return CGSize(width: maxMessageWidth, height: bigImageSize)
        }
    }

    public func mediaView(forLocation location: CGPoint) -> MediaView? {
        var bestMediaView: MediaView?
        var bestDistance: CGFloat = 0
        for itemView in itemViews {
            let itemCenter = convert(itemView.center, from: itemView.superview)
            let distance = location.distance(to: itemCenter)
            if bestMediaView != nil && distance > bestDistance {
                continue
            }
            bestMediaView = itemView
            bestDistance = distance
        }
        return bestMediaView
    }

    public func isMoreItemsView(mediaView: MediaView) -> Bool {
        return moreItemsView == mediaView
    }
}
