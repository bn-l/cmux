import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserNavigationDecisionHandlerTests {
    @Test
    func navigationDecisionHandlerInvokesUnderlyingHandlerAtMostOnce() {
        var policies: [WKNavigationActionPolicy] = []
        let decisionHandler = BrowserNavigationActionDecisionHandler(
            { policies.append($0) },
            fallbackPolicy: WKNavigationActionPolicy.cancel,
            label: "test.double-call"
        )

        decisionHandler(.allow)
        decisionHandler(.download)

        #expect(policies.count == 1)
        #expect(policies.first == .allow)
    }

    @Test
    func navigationDecisionHandlerCancelsWhenConsumedPathDropsHandler() {
        var policies: [WKNavigationActionPolicy] = []
        var droppedHandler: ((WKNavigationActionPolicy) -> Void)? =
            BrowserNavigationActionDecisionHandler(
                { policies.append($0) },
                fallbackPolicy: .cancel,
                label: "test.dropped-consumed-path"
            ).closure

        withExtendedLifetime(droppedHandler) {}
        droppedHandler = nil

        #expect(policies.count == 1)
        #expect(policies.first == .cancel)
    }

    @Test
    func navigationResponseDecisionHandlerUsesCancelFallback() {
        var policies: [WKNavigationResponsePolicy] = []
        var droppedHandler: ((WKNavigationResponsePolicy) -> Void)? =
            BrowserNavigationResponseDecisionHandler(
                { policies.append($0) },
                fallbackPolicy: .cancel,
                label: "test.dropped-response-path"
            ).closure

        withExtendedLifetime(droppedHandler) {}
        droppedHandler = nil

        #expect(policies.count == 1)
        #expect(policies.first == .cancel)
    }
}
