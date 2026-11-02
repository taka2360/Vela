// iOS の UIKit の「形だけ」（Linux で型チェックするためのスタブ。中身は動かない）
@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking   // iOS では Foundation に入っている URLRequest などは、Linux ではこちら
#endif

@MainActor open class UIResponder: NSObject {}

@MainActor open class UIFindInteraction: NSObject {
    open func presentFindNavigator(showingReplace: Bool) {}
    open func dismissFindNavigator() {}
    open var isFindNavigatorVisible: Bool { false }
}

open class UIView: UIResponder {
    public struct AutoresizingMask: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let flexibleLeftMargin = AutoresizingMask(rawValue: 1), flexibleWidth = AutoresizingMask(rawValue: 2)
        public static let flexibleRightMargin = AutoresizingMask(rawValue: 4), flexibleTopMargin = AutoresizingMask(rawValue: 8)
        public static let flexibleHeight = AutoresizingMask(rawValue: 16), flexibleBottomMargin = AutoresizingMask(rawValue: 32)
    }
    public override init() { super.init() }
    public init(frame: CGRect) { super.init() }
    open var subviews: [UIView] { [] }
    open var superview: UIView? { nil }
    open var autoresizingMask: AutoresizingMask = []
    open var frame: CGRect = .zero
    open var bounds: CGRect = .zero
    open var isHidden = false
    open var alpha: CGFloat = 1
    open var backgroundColor: UIColor?
    open func addSubview(_ view: UIView) {}
    open func removeFromSuperview() {}
    open func setNeedsLayout() {}
    open func layoutIfNeeded() {}
}

open class UIColor: NSObject {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { super.init() }
    public init(white: CGFloat, alpha: CGFloat) { super.init() }
    open class var black: UIColor { UIColor(white: 0, alpha: 1) }
    open class var white: UIColor { UIColor(white: 1, alpha: 1) }
    open class var clear: UIColor { UIColor(white: 0, alpha: 0) }
    open class var systemBackground: UIColor { UIColor(white: 1, alpha: 1) }
    open class var secondarySystemBackground: UIColor { UIColor(white: 1, alpha: 1) }
    open class var tertiarySystemBackground: UIColor { UIColor(white: 1, alpha: 1) }
    open class var systemGroupedBackground: UIColor { UIColor(white: 1, alpha: 1) }
    open class var systemFill: UIColor { UIColor(white: 1, alpha: 1) }
    open class var secondarySystemFill: UIColor { UIColor(white: 1, alpha: 1) }
    open class var tertiarySystemFill: UIColor { UIColor(white: 1, alpha: 1) }
    open class var label: UIColor { UIColor(white: 0, alpha: 1) }
    open class var secondaryLabel: UIColor { UIColor(white: 0, alpha: 1) }
}

open class UIScrollView: UIView {
    open var contentOffset: CGPoint = .zero
    open var contentInset = UIEdgeInsets()
    open var isScrollEnabled = true
    open var refreshControl: UIRefreshControl?
}

public struct UIEdgeInsets {
    public var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    public init() {}
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

public enum UIKeyboardType: Int { case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch }

open class UIApplication: UIResponder {
    nonisolated public static let didReceiveMemoryWarningNotification = NSNotification.Name("UIApplicationDidReceiveMemoryWarningNotification")
    nonisolated public static let didEnterBackgroundNotification = NSNotification.Name("UIApplicationDidEnterBackgroundNotification")
    open class var shared: UIApplication { UIApplication() }
    open func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {}
}

open class UIImage: NSObject {
    public init?(systemName: String) { super.init() }
    public init?(data: Data) { super.init() }
}

// MARK: - 部品（コントロール・メニュー・クリップボード）

open class UIControl: UIView {
    public struct Event: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let touchUpInside = Event(rawValue: 1 << 6), valueChanged = Event(rawValue: 1 << 12), primaryActionTriggered = Event(rawValue: 1 << 13)
    }
    open func addAction(_ action: UIAction, for controlEvents: UIControl.Event) {}
    open func removeAction(_ action: UIAction, for controlEvents: UIControl.Event) {}
}

open class UIRefreshControl: UIControl {
    public override init() { super.init() }
    open var isRefreshing: Bool { false }
    open func beginRefreshing() {}
    open func endRefreshing() {}
}

open class UIViewController: UIResponder {
    open var view: UIView! { nil }
}

open class UIMenuElement: NSObject {
    public struct Attributes: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let disabled = Attributes(rawValue: 1), destructive = Attributes(rawValue: 2), hidden = Attributes(rawValue: 4)
    }
    public enum State: Int { case off, on, mixed }
}

public typealias UIActionHandler = (UIAction) -> Void

open class UIAction: UIMenuElement {
    public struct Identifier: Hashable { public init(_ rawValue: String) {} }
    public init(title: String = "", image: UIImage? = nil, identifier: UIAction.Identifier? = nil, discoverabilityTitle: String? = nil,
                attributes: UIMenuElement.Attributes = [], state: UIMenuElement.State = .off, handler: @escaping UIActionHandler) { super.init() }
    open var title: String = ""
}

open class UIMenu: UIMenuElement {
    public struct Identifier: Hashable { public init(_ rawValue: String) {} }
    public struct Options: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let displayInline = Options(rawValue: 1), destructive = Options(rawValue: 2)
    }
    public init(title: String = "", image: UIImage? = nil, identifier: UIMenu.Identifier? = nil, options: UIMenu.Options = [],
                children: [UIMenuElement] = []) { super.init() }
    open var children: [UIMenuElement] { [] }
}

public typealias UIContextMenuContentPreviewProvider = () -> UIViewController?
public typealias UIContextMenuActionProvider = ([UIMenuElement]) -> UIMenu?

open class UIContextMenuConfiguration: NSObject {
    public init(identifier: NSCopying?, previewProvider: UIContextMenuContentPreviewProvider?, actionProvider: UIContextMenuActionProvider?) { super.init() }
}

open class UIPasteboard: NSObject {
    open class var general: UIPasteboard { UIPasteboard() }
    open var string: String?
    open var url: URL?
}

// MARK: - KVO（Linux の Foundation には無いので形だけ。iOS の Foundation と同じ名前）

public struct NSKeyValueObservingOptions: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let new = NSKeyValueObservingOptions(rawValue: 1), old = NSKeyValueObservingOptions(rawValue: 2)
    public static let initial = NSKeyValueObservingOptions(rawValue: 4), prior = NSKeyValueObservingOptions(rawValue: 8)
}

public struct NSKeyValueObservedChange<Value> {
    public let newValue: Value?
    public let oldValue: Value?
}

open class NSKeyValueObservation: NSObject {
    open func invalidate() {}
}

public protocol _KeyValueCodingAndObserving {}
extension NSObject: _KeyValueCodingAndObserving {}
public extension _KeyValueCodingAndObserving {
    func observe<Value>(_ keyPath: KeyPath<Self, Value>, options: NSKeyValueObservingOptions = [],
                        changeHandler: @escaping (Self, NSKeyValueObservedChange<Value>) -> Void) -> NSKeyValueObservation { NSKeyValueObservation() }
}

// MARK: - 共有シート

open class UIActivity: NSObject {}

open class UIActivityViewController: UIViewController {
    public init(activityItems: [Any], applicationActivities: [UIActivity]?) { super.init() }
}
