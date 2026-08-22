// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit

@MainActor
final class FloorpWebContentPolicyCoordinator {
    private static let coordinators = NSMapTable<WKUserContentController, FloorpWebContentPolicyCoordinator>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func coordinator(for controller: WKUserContentController) -> FloorpWebContentPolicyCoordinator {
        if let coordinator = coordinators.object(forKey: controller) {
            return coordinator
        }
        let coordinator = FloorpWebContentPolicyCoordinator(controller: controller)
        coordinators.setObject(coordinator, forKey: controller)
        return coordinator
    }

    private weak var controller: WKUserContentController?
    private var scriptsByOwner = [String: [WKUserScript]]()
    private var rulesByOwner = [String: [WKContentRuleList]]()

    private init(controller: WKUserContentController) {
        self.controller = controller
    }

    func replaceUserScripts(_ scripts: [WKUserScript], ownedBy owner: String) {
        scriptsByOwner[owner] = scripts
        reconcileUserScripts()
    }

    func removeUserScripts(ownedBy owner: String) {
        guard scriptsByOwner.removeValue(forKey: owner) != nil else { return }
        reconcileUserScripts()
    }

    func replaceContentRuleLists(_ rules: [WKContentRuleList], ownedBy owner: String) {
        guard let controller else { return }
        let oldRules = rulesByOwner[owner] ?? []
        oldRules.forEach(controller.remove)
        rulesByOwner[owner] = rules
        rules.forEach(controller.add)
    }

    func removeContentRuleLists(ownedBy owner: String) {
        replaceContentRuleLists([], ownedBy: owner)
    }

    func removeAllPoliciesForFinalTeardown() {
        controller?.removeAllUserScripts()
        controller?.removeAllContentRuleLists()
        scriptsByOwner.removeAll()
        rulesByOwner.removeAll()
    }

    private func reconcileUserScripts() {
        guard let controller else { return }
        controller.removeAllUserScripts()
        for owner in scriptsByOwner.keys.sorted() {
            scriptsByOwner[owner]?.forEach(controller.addUserScript)
        }
    }
}
