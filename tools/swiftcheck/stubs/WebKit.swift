// iOS の WebKit の「形だけ」（Linux で型チェックするためのスタブ。中身は動かない）
// 名前・引数ラベル・型は iOS 16 の SDK の Swift 版に合わせている
@_exported import UIKit

open class WKNavigation: NSObject {}

open class WKSecurityOrigin: NSObject {
    open var `protocol`: String { "" }
    open var host: String { "" }
    open var port: Int { 0 }
}

open class WKFrameInfo: NSObject {
    open var isMainFrame: Bool { true }
    open var request: URLRequest { URLRequest(url: URL(string: "about:blank")!) }
    open var securityOrigin: WKSecurityOrigin { WKSecurityOrigin() }
    open weak var webView: WKWebView? { nil }
}

public enum WKNavigationType: Int { case linkActivated, formSubmitted, backForward, reload, formResubmitted, other = -1 }
public enum WKNavigationActionPolicy: Int { case cancel, allow, download }
public enum WKNavigationResponsePolicy: Int { case cancel, allow, download }

open class WKNavigationAction: NSObject {
    open var request: URLRequest { URLRequest(url: URL(string: "about:blank")!) }
    open var sourceFrame: WKFrameInfo { WKFrameInfo() }
    open var targetFrame: WKFrameInfo? { nil }
    open var navigationType: WKNavigationType { .other }
}

open class WKNavigationResponse: NSObject {
    open var response: URLResponse { fatalError() }
    open var isForMainFrame: Bool { true }
}

@MainActor public protocol WKNavigationDelegate: NSObjectProtocol {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
}
public extension WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy { .allow }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy { .allow }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {}
}

open class WKWindowFeatures: NSObject {}

open class WKContextMenuElementInfo: NSObject {
    open var linkURL: URL? { nil }
}

open class WKSnapshotConfiguration: NSObject {
    open var rect: CGRect = .zero
    open var afterScreenUpdates = true
}

@MainActor public protocol WKUIDelegate: NSObjectProtocol {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView?
    func webViewDidClose(_ webView: WKWebView)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String?
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void)
}
public extension WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webViewDidClose(_ webView: WKWebView) {}
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {}
}

public protocol WKURLSchemeTask: NSObjectProtocol {
    var request: URLRequest { get }
    func didReceive(_ response: URLResponse)
    func didReceive(_ data: Data)
    func didFinish()
    func didFailWithError(_ error: Error)
}

public protocol WKURLSchemeHandler: NSObjectProtocol {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask)
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask)
}

public enum WKUserScriptInjectionTime: Int { case atDocumentStart, atDocumentEnd }

open class WKUserScript: NSObject {
    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) { super.init() }
    open var source: String { "" }
}

open class WKScriptMessage: NSObject {
    open var body: Any { 0 }
    open var name: String { "" }
    open var frameInfo: WKFrameInfo { WKFrameInfo() }
    open weak var webView: WKWebView? { nil }
}

public protocol WKScriptMessageHandler: NSObjectProtocol {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
}

open class WKContentRuleList: NSObject {
    open var identifier: String { "" }
}

open class WKContentRuleListStore: NSObject {
    open class func `default`() -> WKContentRuleListStore { WKContentRuleListStore() }
    open func compileContentRuleList(forIdentifier identifier: String?, encodedContentRuleList: String?,
                                     completionHandler: @escaping (WKContentRuleList?, Error?) -> Void) {}
    open func lookUpContentRuleList(forIdentifier identifier: String?, completionHandler: @escaping (WKContentRuleList?, Error?) -> Void) {}
    open func removeContentRuleList(forIdentifier identifier: String?, completionHandler: @escaping (Error?) -> Void) {}
}

open class WKUserContentController: NSObject {
    open var userScripts: [WKUserScript] { [] }
    open func addUserScript(_ userScript: WKUserScript) {}
    open func removeAllUserScripts() {}
    open func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {}
    open func removeScriptMessageHandler(forName name: String) {}
    open func removeAllScriptMessageHandlers() {}
    open func add(_ contentRuleList: WKContentRuleList) {}
    open func remove(_ contentRuleList: WKContentRuleList) {}
    open func removeAllContentRuleLists() {}
}

public protocol WKHTTPCookieStoreObserver: NSObjectProtocol {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore)
}
public extension WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {}
}

open class WKHTTPCookieStore: NSObject {
    open func add(_ observer: WKHTTPCookieStoreObserver) {}
    open func remove(_ observer: WKHTTPCookieStoreObserver) {}
    open func getAllCookies(_ completionHandler: @escaping @MainActor ([HTTPCookie]) -> Void) {}
    open func allCookies() async -> [HTTPCookie] { [] }
    open func setCookie(_ cookie: HTTPCookie, completionHandler: (@MainActor () -> Void)? = nil) {}
    open func setCookie(_ cookie: HTTPCookie) async {}
    open func delete(_ cookie: HTTPCookie, completionHandler: (@MainActor () -> Void)? = nil) {}
    open func deleteCookie(_ cookie: HTTPCookie) async {}
}

open class WKWebsiteDataStore: NSObject {
    open class func `default`() -> WKWebsiteDataStore { WKWebsiteDataStore() }
    open class func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
    open var httpCookieStore: WKHTTPCookieStore { WKHTTPCookieStore() }
    open var isPersistent: Bool { true }
}

public struct WKAudiovisualMediaTypes: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let audio = WKAudiovisualMediaTypes(rawValue: 1)
    public static let video = WKAudiovisualMediaTypes(rawValue: 2)
    public static let all = WKAudiovisualMediaTypes(rawValue: ~0)
}

open class WKPreferences: NSObject {
    open var javaScriptCanOpenWindowsAutomatically = false
    open var minimumFontSize: CGFloat = 0
    open var isFraudulentWebsiteWarningEnabled = true
}

open class WKWebpagePreferences: NSObject {
    open var allowsContentJavaScript = true
    public enum ContentMode: Int { case recommended = 0, mobile = 1, desktop = 2 }
    open var preferredContentMode: ContentMode = .recommended
}

open class WKWebViewConfiguration: NSObject {
    open var userContentController = WKUserContentController()
    open var websiteDataStore = WKWebsiteDataStore.default()
    open var preferences = WKPreferences()
    open var defaultWebpagePreferences = WKWebpagePreferences()
    open var allowsInlineMediaPlayback = false
    open var allowsAirPlayForMediaPlayback = true
    open var allowsPictureInPictureMediaPlayback = true
    open var mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = .all
    open var applicationNameForUserAgent: String?
    open var limitsNavigationsToAppBoundDomains = false
    open func setURLSchemeHandler(_ urlSchemeHandler: WKURLSchemeHandler?, forURLScheme urlScheme: String) {}
    open func urlSchemeHandler(forURLScheme urlScheme: String) -> WKURLSchemeHandler? { nil }
}

open class WKBackForwardListItem: NSObject {
    open var url: URL { URL(string: "about:blank")! }
    open var title: String? { nil }
}
open class WKBackForwardList: NSObject {
    open var currentItem: WKBackForwardListItem? { nil }
    open var backList: [WKBackForwardListItem] { [] }
    open var forwardList: [WKBackForwardListItem] { [] }
    open var backItem: WKBackForwardListItem? { nil }
    open var forwardItem: WKBackForwardListItem? { nil }
}

@MainActor open class WKWebView: UIView {
    public init(frame: CGRect, configuration: WKWebViewConfiguration) { super.init(frame: frame) }
    @MainActor open var configuration: WKWebViewConfiguration { WKWebViewConfiguration() }
    @MainActor open weak var navigationDelegate: WKNavigationDelegate?
    @MainActor open weak var uiDelegate: WKUIDelegate?
    @MainActor open var url: URL? { nil }
    @MainActor open var title: String? { nil }
    @MainActor open var isLoading: Bool { false }
    @MainActor open var estimatedProgress: Double { 0 }
    @MainActor open var canGoBack: Bool { false }
    @MainActor open var canGoForward: Bool { false }
    @MainActor open var hasOnlySecureContent: Bool { false }
    @MainActor open var interactionState: Any?
    @MainActor open func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?,
                                      completionHandler: @escaping @MainActor (UIImage?, Error?) -> Void) {}
    @MainActor @discardableResult open func go(to item: WKBackForwardListItem) -> WKNavigation? { nil }
    @MainActor open var customUserAgent: String?
    @MainActor open var allowsBackForwardNavigationGestures = false
    @MainActor open var isInspectable = false
    @MainActor open var scrollView: UIScrollView { UIScrollView() }
    @MainActor open var backForwardList: WKBackForwardList { WKBackForwardList() }
    @MainActor @discardableResult open func load(_ request: URLRequest) -> WKNavigation? { nil }
    @MainActor @discardableResult open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }
    @MainActor @discardableResult open func load(_ data: Data, mimeType MIMEType: String, characterEncodingName: String, baseURL: URL) -> WKNavigation? { nil }
    @MainActor @discardableResult open func goBack() -> WKNavigation? { nil }
    @MainActor @discardableResult open func goForward() -> WKNavigation? { nil }
    @MainActor @discardableResult open func reload() -> WKNavigation? { nil }
    @MainActor open func stopLoading() {}
    @MainActor open func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {}
    @MainActor open func evaluateJavaScript(_ javaScriptString: String) async throws -> Any { 0 }
    @MainActor open func callAsyncJavaScript(_ functionBody: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                                             contentWorld: Any) async throws -> Any? { nil }
    // 本物は MainActor の WKWebView の中だが、Objective-C から来た API なので、隔離の食い違いは iPad では警告どまり。スタブでは nonisolated にしておく
    nonisolated open class func handlesURLScheme(_ urlScheme: String) -> Bool { false }
}
