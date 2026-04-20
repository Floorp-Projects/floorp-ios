// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import UniformTypeIdentifiers
import ActionExtensionKit

final class ActionViewController: UIViewController {
    private let floorpURLBuilder: FloorpURLBuilding

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.floorpURLBuilder = FloorpURLBuilder()
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    init(floorpURLBuilder: FloorpURLBuilding) {
        self.floorpURLBuilder = floorpURLBuilder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        handleShareExtension()
    }

    private func setupView() {
        view.backgroundColor = .clear
        view.alpha = 0
    }

    private func handleShareExtension() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            finishExtension(with: nil)
            return
        }

        floorpURLBuilder.findURLInItems(inputItems) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let shareItem):
                self.openFloorp(with: .shareItem(shareItem))

            case .failure:
                self.floorpURLBuilder.findTextInItems(inputItems) { textResult in
                    switch textResult {
                    case .success(let extractedItem):
                        self.openFloorp(with: extractedItem)
                    case let .failure(error):
                        self.finishExtension(with: error)
                    }
                }
            }
        }
    }

    private func openFloorp(with shareItem: ExtractedShareItem) {
        guard let floorpURL = floorpURLBuilder.buildFloorpURL(from: shareItem) else {
            finishExtension(with: nil)
            return
        }

        openURL(floorpURL)
        finishExtension(with: nil)
    }

    private func openURL(_ url: URL) {
        var responder: UIResponder? = self

        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func finishExtension(with error: Error?) {
        if let error {
            extensionContext?.cancelRequest(withError: error)
        } else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
