// iOS の UIKit の「形だけ」（Linux で型チェックするためのスタブ。中身は動かない）
@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking   // iOS では Foundation に入っている URLRequest などは、Linux ではこちら
#endif

@MainActor open class UIResponder: NSObject {}

open class UIView: UIResponder {
    public override init() { super.init() }
    public init(frame: CGRect) { super.init() }
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
}

open class UIScrollView: UIView {
    open var contentOffset: CGPoint = .zero
    open var contentInset = UIEdgeInsets()
    open var isScrollEnabled = true
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
    open class var shared: UIApplication { UIApplication() }
    open func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {}
}

open class UIImage: NSObject {
    public init?(systemName: String) { super.init() }
    public init?(data: Data) { super.init() }
}
