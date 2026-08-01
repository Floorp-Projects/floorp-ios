// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import MLPAKit
import LLMKit
import Shared

// MARK: - Protocol
/// Creates a ResultsService with using MLPA (App Attest) authentication and LiteLLM.
protocol ResultsServiceFactory {
    func make(prefs: Prefs, configFetcher: QuickAnswersConfigFetcher) throws -> ResultsService
}

// MARK: - Default Implementation
public struct DefaultResultsServiceFactory: ResultsServiceFactory {
    let liteLLMCreator: LiteLLMCreating
    let allowsQuickAnswers: Bool

    public init(
        liteLLMCreator: LiteLLMCreating,
        allowsQuickAnswers: Bool = AppServicesPolicy.allowsQuickAnswers
    ) {
        self.liteLLMCreator = liteLLMCreator
        self.allowsQuickAnswers = allowsQuickAnswers
    }

    func make(
        prefs: Prefs,
        configFetcher: QuickAnswersConfigFetcher
    ) throws -> ResultsService {
        guard allowsQuickAnswers else {
            throw ResultsServiceError.unableToCreateService
        }
        guard let client = makeLiteLLMClient(prefs: prefs) else {
            throw ResultsServiceError.unableToCreateService
        }

        return DefaultResultsService(client: client, configFetcher: configFetcher)
    }

    // MARK: - Private Helpers
    private func makeLiteLLMClient(prefs: Prefs) -> LiteLLMClientProtocol? {
        return liteLLMCreator.createAppAttestLiteLLM(using: prefs, serviceType: .quickAnswers)
    }
}
