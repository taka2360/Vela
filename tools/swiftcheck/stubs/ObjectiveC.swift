// iOS の ObjectiveC ランタイムの「形だけ」（Linux で型チェックするためのスタブ）
// 注意: Linux の Swift には Objective-C の仕組みが無いので、@convention(block) などは検査できない（check.sh が「検査不可」として扱う）
@_exported import Foundation

public struct Selector: Hashable, ExpressibleByStringLiteral {
    public init(_ name: String) {}
    public init(stringLiteral value: String) {}
}

public func NSSelectorFromString(_ s: String) -> Selector { Selector(s) }
public func NSStringFromSelector(_ s: Selector) -> String { "" }

public typealias IMP = OpaquePointer
public typealias Method = OpaquePointer
public typealias Ivar = OpaquePointer

public func class_getClassMethod(_ cls: AnyClass?, _ name: Selector) -> Method? { nil }
public func class_getInstanceMethod(_ cls: AnyClass?, _ name: Selector) -> Method? { nil }
public func method_getImplementation(_ m: Method) -> IMP { m }
public func method_setImplementation(_ m: Method, _ imp: IMP) -> IMP { imp }
public func method_exchangeImplementations(_ m1: Method, _ m2: Method) {}
public func imp_implementationWithBlock(_ block: Any) -> IMP { fatalError() }
public func class_addMethod(_ cls: AnyClass?, _ name: Selector, _ imp: IMP, _ types: UnsafePointer<CChar>?) -> Bool { false }
public func object_getClass(_ obj: Any?) -> AnyClass? { nil }
public func objc_getAssociatedObject(_ object: Any, _ key: UnsafeRawPointer) -> Any? { nil }
public func objc_setAssociatedObject(_ object: Any, _ key: UnsafeRawPointer, _ value: Any?, _ policy: objc_AssociationPolicy) {}
public enum objc_AssociationPolicy: UInt { case OBJC_ASSOCIATION_ASSIGN = 0, OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1, OBJC_ASSOCIATION_COPY_NONATOMIC = 3, OBJC_ASSOCIATION_RETAIN = 769, OBJC_ASSOCIATION_COPY = 771 }
