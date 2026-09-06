// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import WebKit

final class TabContentScriptManager: NSObject, WKScriptMessageHandler {
    private enum HandlerContentWorld {
        case defaultClient
        case page
        case custom(String)

        @MainActor var webKitValue: WKContentWorld {
            switch self {
            case .defaultClient:
                return .defaultClient
            case .page:
                return .page
            case .custom(let name):
                return .world(name: name)
            }
        }
    }

    private struct RegisteredHandler {
        let name: String
        let contentWorld: HandlerContentWorld
    }

    private var helpers = [String: TabContentScript]()
    private var registeredHandlers = [String: [RegisteredHandler]]()

    // Without calling this, the TabContentScriptManager will leak.
    func uninstall(tab: Tab) {
        if let userContentController = tab.webView?.configuration.userContentController {
            registeredHandlers.values.flatMap { $0 }.forEach { handler in
                userContentController.removeScriptMessageHandler(
                    forName: handler.name,
                    contentWorld: handler.contentWorld.webKitValue
                )
            }
        }
        helpers.forEach { helper in
            helper.value.prepareForDeinit()
        }
        // See ADR-10 for context on `helpers.removeAll()`
        helpers.removeAll()
        registeredHandlers.removeAll()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        for helper in helpers.values {
            if let scriptMessageHandlerNames = helper.scriptMessageHandlerNames(),
               scriptMessageHandlerNames.contains(message.name) {
                helper.userContentController(userContentController, didReceiveScriptMessage: message)
                return
            }
        }
    }

    func addContentScript(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        // If a helper script already exists on a tab, skip adding this duplicate.
        guard helpers[name] == nil else { return }

        helpers[name] = helper

        // If this helper handles script messages, then get the handlers names and register them. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        helper.scriptMessageHandlerNames()?.forEach { scriptMessageHandlerName in
            guard let userContentController = tab.webView?.configuration.userContentController else { return }
            userContentController.addInDefaultContentWorld(
                scriptMessageHandler: self,
                name: scriptMessageHandlerName
            )
            registeredHandlers[name, default: []].append(
                RegisteredHandler(name: scriptMessageHandlerName, contentWorld: .defaultClient)
            )
        }
    }

    func addContentScriptToPage(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        // If a helper script already exists on the page, skip adding this duplicate.
        guard helpers[name] == nil else { return }

        helpers[name] = helper

        // If this helper handles script messages, then get the handlers names and register them. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        helper.scriptMessageHandlerNames()?.forEach { scriptMessageHandlerName in
            guard let userContentController = tab.webView?.configuration.userContentController else { return }
            userContentController.addInPageContentWorld(
                scriptMessageHandler: self,
                name: scriptMessageHandlerName
            )
            registeredHandlers[name, default: []].append(
                RegisteredHandler(name: scriptMessageHandlerName, contentWorld: .page)
            )
        }
    }

    func addContentScriptToCustomWorld(_ helper: TabContentScript, name: String, forTab tab: Tab) {
        // If a helper script already exists on the page, skip adding this duplicate.
        guard helpers[name] == nil else { return }

        helpers[name] = helper

        // If this helper handles script messages, then get the handlers names and register them. The Browser
        // receives all messages and then dispatches them to the right TabHelper.
        helper.scriptMessageHandlerNames()?.forEach { scriptMessageHandlerName in
            guard let userContentController = tab.webView?.configuration.userContentController else { return }
            userContentController.addInCustomContentWorld(
                scriptMessageHandler: self,
                name: scriptMessageHandlerName
            )
            registeredHandlers[name, default: []].append(
                RegisteredHandler(
                    name: scriptMessageHandlerName,
                    contentWorld: .custom(scriptMessageHandlerName)
                )
            )
        }
    }

    func getContentScript(_ name: String) -> TabContentScript? {
        return helpers[name]
    }
}
