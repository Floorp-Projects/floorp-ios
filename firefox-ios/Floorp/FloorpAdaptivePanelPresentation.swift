// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

enum FloorpPanelPresentationMode: Equatable {
    case overlay
    case pinned
}

typealias FloorpPanelPresentationModeProvider = @MainActor (
    _ availableWidth: CGFloat,
    _ horizontalSizeClass: UIUserInterfaceSizeClass
) -> FloorpPanelPresentationMode

struct FloorpPanelPresentationModeResolver {
    static let minimumUsableBrowserWidth: CGFloat = 500

    static func resolve(
        availableWidth: CGFloat,
        horizontalSizeClass: UIUserInterfaceSizeClass,
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) -> FloorpPanelPresentationMode {
        guard userInterfaceIdiom == .pad,
              horizontalSizeClass == .regular,
              availableWidth >= minimumUsableBrowserWidth
                + CGFloat(FloorpWebPanelPreferences.minimumContentWidth) else {
            return .overlay
        }
        return .pinned
    }
}

@MainActor
final class FloorpBrowserContentLayoutGuides {
    let fullWidth: UILayoutGuide
    let safeArea: UILayoutGuide

    private weak var parentView: UIView?
    private let fullLeftConstraint: NSLayoutConstraint
    private let fullRightConstraint: NSLayoutConstraint
    private let safeLeftToSafeAreaConstraint: NSLayoutConstraint
    private let safeLeftToFullWidthConstraint: NSLayoutConstraint
    private let safeRightToSafeAreaConstraint: NSLayoutConstraint
    private let safeRightToFullWidthConstraint: NSLayoutConstraint
    private(set) var reservedSidebarWidth: CGFloat = 0
    private(set) var layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight

    init(parentView: UIView) {
        let fullWidth = UILayoutGuide()
        let safeArea = UILayoutGuide()
        let fullLeftConstraint = fullWidth.leftAnchor.constraint(equalTo: parentView.leftAnchor)
        let fullRightConstraint = fullWidth.rightAnchor.constraint(equalTo: parentView.rightAnchor)
        let safeLeftToSafeAreaConstraint = safeArea.leftAnchor.constraint(
            equalTo: parentView.safeAreaLayoutGuide.leftAnchor
        )
        let safeLeftToFullWidthConstraint = safeArea.leftAnchor.constraint(
            equalTo: fullWidth.leftAnchor
        )
        let safeRightToSafeAreaConstraint = safeArea.rightAnchor.constraint(
            equalTo: parentView.safeAreaLayoutGuide.rightAnchor
        )
        let safeRightToFullWidthConstraint = safeArea.rightAnchor.constraint(
            equalTo: fullWidth.rightAnchor
        )
        self.fullWidth = fullWidth
        self.safeArea = safeArea
        self.parentView = parentView
        self.fullLeftConstraint = fullLeftConstraint
        self.fullRightConstraint = fullRightConstraint
        self.safeLeftToSafeAreaConstraint = safeLeftToSafeAreaConstraint
        self.safeLeftToFullWidthConstraint = safeLeftToFullWidthConstraint
        self.safeRightToSafeAreaConstraint = safeRightToSafeAreaConstraint
        self.safeRightToFullWidthConstraint = safeRightToFullWidthConstraint
        parentView.addLayoutGuide(fullWidth)
        parentView.addLayoutGuide(safeArea)
        NSLayoutConstraint.activate([
            fullLeftConstraint,
            fullRightConstraint,
            safeLeftToSafeAreaConstraint,
            safeRightToSafeAreaConstraint,
        ])
    }

    @discardableResult
    func reserveSidebar(
        width: CGFloat,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Bool {
        let normalizedWidth = max(0, width)
        guard normalizedWidth != reservedSidebarWidth || layoutDirection != self.layoutDirection else {
            return false
        }

        reservedSidebarWidth = normalizedWidth
        self.layoutDirection = layoutDirection
        let leftInset = layoutDirection == .rightToLeft ? normalizedWidth : 0
        let rightInset = layoutDirection == .rightToLeft ? 0 : normalizedWidth
        fullLeftConstraint.constant = leftInset
        fullRightConstraint.constant = -rightInset
        updateSafeAreaIntersection(
            hasReservation: normalizedWidth > 0,
            layoutDirection: layoutDirection
        )
        parentView?.setNeedsLayout()
        return true
    }

    private func updateSafeAreaIntersection(
        hasReservation: Bool,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) {
        NSLayoutConstraint.deactivate([
            safeLeftToSafeAreaConstraint,
            safeLeftToFullWidthConstraint,
            safeRightToSafeAreaConstraint,
            safeRightToFullWidthConstraint,
        ])
        if !hasReservation {
            NSLayoutConstraint.activate([
                safeLeftToSafeAreaConstraint,
                safeRightToSafeAreaConstraint,
            ])
        } else if layoutDirection == .rightToLeft {
            NSLayoutConstraint.activate([
                safeLeftToFullWidthConstraint,
                safeRightToSafeAreaConstraint,
            ])
        } else {
            NSLayoutConstraint.activate([
                safeLeftToSafeAreaConstraint,
                safeRightToFullWidthConstraint,
            ])
        }
    }
}

final class FloorpDrawerRootView: UIView {
    weak var drawerContainerView: UIView?
    weak var resizeHandleView: UIView?
    var passesTouchesOutsideDrawer = false

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard passesTouchesOutsideDrawer else {
            return super.point(inside: point, with: event)
        }
        guard super.point(inside: point, with: event) else { return false }
        let touchesContainer = drawerContainerView?.frame.contains(point) == true
        let touchesResizeHandle = resizeHandleView?.frame.contains(point) == true
        return touchesContainer || touchesResizeHandle
    }
}

final class FloorpPanelResizeHandleView: UIControl {
    var onAccessibilityIncrement: (() -> Void)?
    var onAccessibilityDecrement: (() -> Void)?

    private let grabberView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 1.5
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "Floorp.Drawer.ResizeHandle"
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabberView)
        NSLayoutConstraint.activate([
            grabberView.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabberView.centerYAnchor.constraint(equalTo: centerYAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: 3),
            grabberView.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyColor(_ color: UIColor) {
        grabberView.backgroundColor = color
    }

    override func accessibilityIncrement() {
        onAccessibilityIncrement?()
    }

    override func accessibilityDecrement() {
        onAccessibilityDecrement?()
    }
}
