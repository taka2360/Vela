// iOS の SwiftUI（と Combine の ObservableObject・@Published）の「形だけ」
// Linux で型チェックするためのスタブ。中身は動かない。名前・引数ラベルは iOS 16 の SDK に合わせている。
// よく使うものだけ。足りない部品で「cannot find 'Xxx' in scope」が出たら、ここに足す（本物の SDK と同じ形で）
@_exported import UIKit

// MARK: - Combine の一部

public protocol ObservableObject: AnyObject {}
public final class ObservableObjectPublisher { public init() {}; public func send() {} }
public extension ObservableObject {
    var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public struct Publisher { }
    public var projectedValue: Publisher { get { Publisher() } set {} }
}

// MARK: - 土台

public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor var body: Body { get }
}
extension Never: View { public typealias Body = Never; public var body: Never { fatalError() } }

public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder @MainActor var body: Body { get }
}
extension Never: Scene {}

public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor var body: Body { get }
    @MainActor init()
}
public extension App { @MainActor static func main() {} }

@resultBuilder public enum SceneBuilder {
    public static func buildBlock<C: Scene>(_ c: C) -> C { c }
}

public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    public init(_ title: String, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

public struct TupleView<T>: View { public init(_ value: T) {}; public var body: Never { fatalError() } }
public struct _ConditionalContent<T: View, F: View>: View { public var body: Never { fatalError() } }
extension Optional: View where Wrapped: View { public var body: Never { fatalError() } }

@resultBuilder public enum ViewBuilder {
    public static func buildExpression<C: View>(_ c: C) -> C { c }
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<C: View>(_ c: C) -> C { c }
    public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> TupleView<(C0, C1)> { TupleView((c0, c1)) }
    public static func buildBlock<C0: View, C1: View, C2: View>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleView<(C0, C1, C2)> { TupleView((c0, c1, c2)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleView<(C0, C1, C2, C3)> { TupleView((c0, c1, c2, c3)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleView<(C0, C1, C2, C3, C4)> { TupleView((c0, c1, c2, c3, c4)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleView<(C0, C1, C2, C3, C4, C5)> { TupleView((c0, c1, c2, c3, c4, c5)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleView<(C0, C1, C2, C3, C4, C5, C6)> { TupleView((c0, c1, c2, c3, c4, c5, c6)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleView<(C0, C1, C2, C3, C4, C5, C6, C7)> { TupleView((c0, c1, c2, c3, c4, c5, c6, c7)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> TupleView<(C0, C1, C2, C3, C4, C5, C6, C7, C8)> { TupleView((c0, c1, c2, c3, c4, c5, c6, c7, c8)) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View, C8: View, C9: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> TupleView<(C0, C1, C2, C3, C4, C5, C6, C7, C8, C9)> { TupleView((c0, c1, c2, c3, c4, c5, c6, c7, c8, c9)) }
    public static func buildIf<C: View>(_ c: C?) -> C? { c }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildLimitedAvailability<C: View>(_ c: C) -> AnyView { AnyView(c) }
}

// MARK: - 状態

@propertyWrapper public struct Binding<Value> {
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public static func constant(_ value: Value) -> Binding<Value> { fatalError() }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}

@propertyWrapper public struct State<Value> {
    public init(wrappedValue value: Value) {}
    public init(initialValue value: Value) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}

@propertyWrapper public struct ObservedObject<ObjectType: ObservableObject> {
    @dynamicMemberLookup public struct Wrapper {
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> { fatalError() }
    }
    public init(wrappedValue: ObjectType) {}
    public init(initialValue: ObjectType) {}
    @MainActor public var wrappedValue: ObjectType { fatalError() }
    @MainActor public var projectedValue: Wrapper { fatalError() }
}

@propertyWrapper public struct StateObject<ObjectType: ObservableObject> {
    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {}
    @MainActor public var wrappedValue: ObjectType { fatalError() }
    @MainActor public var projectedValue: ObservedObject<ObjectType>.Wrapper { fatalError() }
}

@propertyWrapper public struct EnvironmentObject<ObjectType: ObservableObject> {
    public init() {}
    @MainActor public var wrappedValue: ObjectType { fatalError() }
    @MainActor public var projectedValue: ObservedObject<ObjectType>.Wrapper { fatalError() }
}

@propertyWrapper public struct AppStorage<Value> {
    public init(wrappedValue: Value, _ key: String) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}

// MARK: - 値の種類

public struct UnitPoint: Hashable {
    public var x: CGFloat, y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public static let zero = UnitPoint(x: 0, y: 0), center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5), trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0), bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0), topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1), bottomTrailing = UnitPoint(x: 1, y: 1)
}

public struct HorizontalAlignment: Equatable { public static let leading = HorizontalAlignment(), center = HorizontalAlignment(), trailing = HorizontalAlignment() }
public struct VerticalAlignment: Equatable { public static let top = VerticalAlignment(), center = VerticalAlignment(), bottom = VerticalAlignment(), firstTextBaseline = VerticalAlignment(), lastTextBaseline = VerticalAlignment() }
public struct Alignment: Equatable {
    public var horizontal: HorizontalAlignment, vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) { self.horizontal = horizontal; self.vertical = vertical }
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

public enum Edge: Int8 {
    case top, leading, bottom, trailing
    public struct Set: OptionSet {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2), bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let all = Set(rawValue: 15), horizontal = Set(rawValue: 10), vertical = Set(rawValue: 5)
    }
}

public enum Axis: Int8 {
    case horizontal, vertical
    public struct Set: OptionSet {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2)
    }
}

public struct Font: Hashable {
    public enum Design: Hashable { case `default`, serif, rounded, monospaced }
    public struct Weight: Hashable { public static let ultraLight = Weight(), thin = Weight(), light = Weight(), regular = Weight(), medium = Weight(), semibold = Weight(), bold = Weight(), heavy = Weight(), black = Weight() }
    public enum TextStyle: Hashable { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
    public static let largeTitle = Font(), title = Font(), title2 = Font(), title3 = Font(), headline = Font(), subheadline = Font()
    public static let body = Font(), callout = Font(), footnote = Font(), caption = Font(), caption2 = Font()
    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font { Font() }
    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font { Font() }
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospaced() -> Font { self }
    public func weight(_ weight: Weight) -> Font { self }
}

public protocol ShapeStyle {}
public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle(), secondary = HierarchicalShapeStyle(), tertiary = HierarchicalShapeStyle(), quaternary = HierarchicalShapeStyle()
}
public extension ShapeStyle where Self == HierarchicalShapeStyle {
    static var primary: HierarchicalShapeStyle { .primary }
    static var secondary: HierarchicalShapeStyle { .secondary }
    static var tertiary: HierarchicalShapeStyle { .tertiary }
}
public struct ForegroundStyle: ShapeStyle { public init() {} }
public extension ShapeStyle where Self == ForegroundStyle { static var foreground: ForegroundStyle { ForegroundStyle() } }

public struct Color: View, ShapeStyle, Hashable {
    public init(_ uiColor: UIColor) {}
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public init(white: Double, opacity: Double = 1) {}
    public init(_ name: String) {}
    public static let black = Color(white: 0), white = Color(white: 1), gray = Color(white: 0.5), clear = Color(white: 0, opacity: 0)
    public static let red = Color(white: 0), green = Color(white: 0), blue = Color(white: 0), orange = Color(white: 0), yellow = Color(white: 0)
    public static let pink = Color(white: 0), purple = Color(white: 0), mint = Color(white: 0), teal = Color(white: 0), cyan = Color(white: 0), indigo = Color(white: 0), brown = Color(white: 0)
    public static let primary = Color(white: 0), secondary = Color(white: 0), accentColor = Color(white: 0)
    public func opacity(_ opacity: Double) -> Color { self }
    public var body: Never { fatalError() }
}
public extension ShapeStyle where Self == Color {
    static var black: Color { .black }; static var white: Color { .white }; static var gray: Color { .gray }; static var clear: Color { .clear }
    static var red: Color { .red }; static var green: Color { .green }; static var blue: Color { .blue }; static var orange: Color { .orange }
    static var yellow: Color { .yellow }; static var accentColor: Color { .accentColor }
}

public struct FillStyle: Equatable { public init(eoFill: Bool = false, antialiased: Bool = true) {} }
public struct StrokeStyle: Equatable { public init(lineWidth: CGFloat = 1, dash: [CGFloat] = []) {} }

public protocol Shape: View {}
public extension Shape {
    var body: Never { fatalError() }
    func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View { self }
    func fill(style: FillStyle = FillStyle()) -> some View { self }
    func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { self }
    func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle) -> some View { self }
    func stroke(lineWidth: CGFloat = 1) -> some Shape { self }
}
public enum RoundedCornerStyle: Hashable { case circular, continuous }
public struct RoundedRectangle: Shape {
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) {}
}
public struct Rectangle: Shape { public init() {} }
public struct Circle: Shape { public init() {} }
public struct Capsule: Shape { public init() {} }

// MARK: - 部品

public struct EmptyView: View { public init() {}; public var body: Never { fatalError() } }
public struct AnyView: View { public init<V: View>(_ view: V) {}; public var body: Never { fatalError() } }
public struct Spacer: View { public init(minLength: CGFloat? = nil) {}; public var body: Never { fatalError() } }
public struct Divider: View { public init() {}; public var body: Never { fatalError() } }

public struct LocalizedStringKey: Hashable, ExpressibleByStringInterpolation {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
}

public struct Text: View, Equatable {
    public init(_ key: LocalizedStringKey) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(verbatim content: String) {}
    public init(_ image: Image) {}
    public var body: Never { fatalError() }
    public func font(_ font: Font?) -> Text { self }
    public func bold() -> Text { self }
    public func italic() -> Text { self }
    public func fontWeight(_ weight: Font.Weight?) -> Text { self }
    public func foregroundColor(_ color: Color?) -> Text { self }
    public func monospacedDigit() -> Text { self }
    public static func + (a: Text, b: Text) -> Text { a }
}

public enum ContentMode: Hashable { case fit, fill }

public struct Image: View, Equatable {
    public init(systemName: String) {}
    public init(_ name: String) {}
    public init(uiImage: UIImage) {}
    public var body: Never { fatalError() }
    public func resizable() -> Image { self }
}

public struct Label<Title: View, Icon: View>: View {
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
    public var body: Never { fatalError() }
}
public extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

public struct VStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct HStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct LazyVStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct Group<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

public struct ScrollView<Content: View>: View {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct ScrollViewProxy {
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {}
}
public struct ScrollViewReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {}
    public var body: Never { fatalError() }
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public var body: Never { fatalError() }
}
public extension ForEach where Data == Range<Int>, ID == Int {
    init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {}
}
public extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

public struct List<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct Section<Parent, Content, Footer> { }
extension Section: View where Parent: View, Content: View, Footer: View { public var body: Never { fatalError() } }
public extension Section where Parent: View, Content: View, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
    init(header: Parent, @ViewBuilder content: () -> Content) {}
}
public extension Section where Parent == Text, Content: View, Footer == EmptyView {
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}
public extension ForEach {
    func onDelete(perform action: ((IndexSet) -> Void)?) -> ModifiedContent<Self, _Mod> { .init() }
}
public protocol PickerStyle {}
public struct SegmentedPickerStyle: PickerStyle { public init() {} }
public extension PickerStyle where Self == SegmentedPickerStyle { static var segmented: SegmentedPickerStyle { .init() } }
public extension View {
    func pickerStyle<S: PickerStyle>(_ style: S) -> ModifiedContent<Self, _Mod> { .init() }
    func tag<V: Hashable>(_ tag: V) -> ModifiedContent<Self, _Mod> { .init() }
    func listStyle<S: ListStyle>(_ style: S) -> ModifiedContent<Self, _Mod> { .init() }
}
public protocol ListStyle {}
public struct PlainListStyle: ListStyle { public init() {} }
public struct InsetGroupedListStyle: ListStyle { public init() {} }
public extension ListStyle where Self == PlainListStyle { static var plain: PlainListStyle { .init() } }
public extension ListStyle where Self == InsetGroupedListStyle { static var insetGrouped: InsetGroupedListStyle { .init() } }

public struct NavigationView<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}
public struct NavigationStack<Content: View>: View {
    public init(@ViewBuilder root: () -> Content) {}
    public var body: Never { fatalError() }
}

public struct ButtonRole: Equatable {
    public static let destructive = ButtonRole(), cancel = ButtonRole()
}

public struct Button<Label: View>: View {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
public extension Button where Label == Text {
    init(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) {}
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) {}
    init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping () -> Void) {}
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping () -> Void) {}
}

public struct Toggle<Label: View>: View {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
public extension Toggle where Label == Text {
    init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}
}

public struct TextField<Label: View>: View {
    public var body: Never { fatalError() }
}
public extension TextField where Label == Text {
    init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {}
}

public struct SecureField<Label: View>: View { public var body: Never { fatalError() } }
public extension SecureField where Label == Text {
    init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
}

public struct ProgressView<Label: View, CurrentValueLabel: View>: View { public var body: Never { fatalError() } }
public extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    init() {}
    init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {}
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View { public var body: Never { fatalError() } }
public extension Picker where Label == Text {
    init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}

// MARK: - スタイル

public protocol TextFieldStyle {}
public struct RoundedBorderTextFieldStyle: TextFieldStyle { public init() {} }
public struct PlainTextFieldStyle: TextFieldStyle { public init() {} }
public extension TextFieldStyle where Self == RoundedBorderTextFieldStyle { static var roundedBorder: RoundedBorderTextFieldStyle { .init() } }
public extension TextFieldStyle where Self == PlainTextFieldStyle { static var plain: PlainTextFieldStyle { .init() } }

public protocol PrimitiveButtonStyle {}
public struct BorderedButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderlessButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct PlainButtonStyle: PrimitiveButtonStyle { public init() {} }
public extension PrimitiveButtonStyle where Self == BorderedButtonStyle { static var bordered: BorderedButtonStyle { .init() } }
public extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { static var borderedProminent: BorderedProminentButtonStyle { .init() } }
public extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { static var borderless: BorderlessButtonStyle { .init() } }
public extension PrimitiveButtonStyle where Self == PlainButtonStyle { static var plain: PlainButtonStyle { .init() } }

public protocol TextSelectability {}
public struct EnabledTextSelectability: TextSelectability {}
public struct DisabledTextSelectability: TextSelectability {}
public extension TextSelectability where Self == EnabledTextSelectability { static var enabled: EnabledTextSelectability { .init() } }
public extension TextSelectability where Self == DisabledTextSelectability { static var disabled: DisabledTextSelectability { .init() } }

public struct TextInputAutocapitalization {
    public static let never = TextInputAutocapitalization(), words = TextInputAutocapitalization()
    public static let sentences = TextInputAutocapitalization(), characters = TextInputAutocapitalization()
}

public struct SubmitTriggers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1), search = SubmitTriggers(rawValue: 2)
}

// MARK: - 見た目の指定（modifier）

public struct ModifiedContent<Content, Modifier> { }
extension ModifiedContent: View where Content: View { public var body: Never { fatalError() } }
public struct _Mod {}

public extension View {
    typealias _M = ModifiedContent<Self, _Mod>
    func font(_ font: Font?) -> _M { .init() }
    func foregroundColor(_ color: Color?) -> _M { .init() }
    func foregroundStyle<S: ShapeStyle>(_ style: S) -> _M { .init() }
    func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> _M { .init() }
    func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
               minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
               alignment: Alignment = .center) -> _M { .init() }
    func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> _M { .init() }
    func padding(_ length: CGFloat) -> _M { .init() }
    func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> _M { .init() }
    func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> _M { .init() }
    func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> _M { .init() }
    func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> _M { .init() }
    func background<V: View>(_ background: V, alignment: Alignment = .center) -> _M { .init() }
    func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> _M { .init() }
    func opacity(_ opacity: Double) -> _M { .init() }
    func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> _M { .init() }
    func id<ID: Hashable>(_ id: ID) -> _M { .init() }
    func disabled(_ disabled: Bool) -> _M { .init() }
    func hidden() -> _M { .init() }
    func lineLimit(_ number: Int?) -> _M { .init() }
    func multilineTextAlignment(_ alignment: TextAlignment) -> _M { .init() }
    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> _M { .init() }
    func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> _M { .init() }
    func textSelection<S: TextSelectability>(_ selectability: S) -> _M { .init() }
    func autocorrectionDisabled(_ disable: Bool = true) -> _M { .init() }
    func disableAutocorrection(_ disable: Bool?) -> _M { .init() }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> _M { .init() }
    func keyboardType(_ type: UIKeyboardType) -> _M { .init() }
    func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> _M { .init() }
    func onAppear(perform action: (() -> Void)? = nil) -> _M { .init() }
    func onDisappear(perform action: (() -> Void)? = nil) -> _M { .init() }
    func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> _M { .init() }
    func onChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> _M { .init() }
    func task(priority: TaskPriority = .userInitiated, _ action: @escaping @Sendable () async -> Void) -> _M { .init() }
    func navigationTitle<S: StringProtocol>(_ title: S) -> _M { .init() }
    func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> _M { .init() }
    func edgesIgnoringSafeArea(_ edges: Edge.Set) -> _M { .init() }
    func shadow(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> _M { .init() }
    func environmentObject<T: ObservableObject>(_ object: T) -> _M { .init() }
    func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> _M { .init() }
    func alert<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A) -> _M { .init() }
    func alert<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A,
                                                   @ViewBuilder message: () -> M) -> _M { .init() }
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> _M { .init() }
    func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> _M { .init() }
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> _M { .init() }
    func focused(_ condition: FocusState<Bool>.Binding) -> _M { .init() }
    func submitLabel(_ submitLabel: SubmitLabel) -> _M { .init() }
    func modifier<T: ViewModifier>(_ modifier: T) -> ModifiedContent<Self, T> { .init() }
    func scaleEffect(_ s: CGFloat, anchor: UnitPoint = .center) -> _M { .init() }
    func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> _M { .init() }
}

public enum TextAlignment: Hashable { case leading, center, trailing }
public struct SafeAreaRegions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let all = SafeAreaRegions(rawValue: 3), container = SafeAreaRegions(rawValue: 1), keyboard = SafeAreaRegions(rawValue: 2)
}

// MARK: - UIKit の部品を入れる

public struct UIViewRepresentableContext<Representable: UIViewRepresentable> {
    public var coordinator: Representable.Coordinator { fatalError() }
}

public protocol UIViewRepresentable: View where Body == Never {
    associatedtype UIViewType: UIView
    associatedtype Coordinator = Void
    typealias Context = UIViewRepresentableContext<Self>
    @MainActor func makeUIView(context: Context) -> UIViewType
    @MainActor func updateUIView(_ uiView: UIViewType, context: Context)
    @MainActor func makeCoordinator() -> Coordinator
}
public extension UIViewRepresentable where Coordinator == Void {
    func makeCoordinator() -> Coordinator { () }
}
public extension UIViewRepresentable {
    var body: Never { fatalError() }
}

// MARK: - 環境・フォーカス・メニュー・格子など（フェーズ C で足したもの）

public enum ScenePhase: Hashable { case background, inactive, active }

public struct DismissAction {
    @MainActor public func callAsFunction() {}
}

public struct EnvironmentValues {
    public var scenePhase: ScenePhase { .active }
    public var dismiss: DismissAction { DismissAction() }
}

@propertyWrapper public struct Environment<Value> {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    @MainActor public var wrappedValue: Value { fatalError() }
}

@propertyWrapper public struct FocusState<Value: Hashable> {
    @propertyWrapper public struct Binding {
        public init() {}
        public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
        public var projectedValue: FocusState<Value>.Binding { self }
    }
    // 本物は init() where Value == Bool と init<T>() where Value == T?。スタブでは 1 つにまとめる
    public init() {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: FocusState<Value>.Binding { fatalError() }
}

public struct SubmitLabel {
    public static let done = SubmitLabel(), go = SubmitLabel(), send = SubmitLabel(), join = SubmitLabel(), route = SubmitLabel()
    public static let search = SubmitLabel(), `return` = SubmitLabel(), next = SubmitLabel(), `continue` = SubmitLabel()
}

public struct KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(_ character: Character) {}
    public init(extendedGraphemeClusterLiteral value: Character) {}
    public static let upArrow = KeyEquivalent("u"), downArrow = KeyEquivalent("d"), leftArrow = KeyEquivalent("l"), rightArrow = KeyEquivalent("r")
    public static let escape = KeyEquivalent("e"), delete = KeyEquivalent("x"), tab = KeyEquivalent("t"), space = KeyEquivalent(" "), `return` = KeyEquivalent("n")
}

public struct EventModifiers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = EventModifiers(rawValue: 1), shift = EventModifiers(rawValue: 2), control = EventModifiers(rawValue: 4)
    public static let option = EventModifiers(rawValue: 8), command = EventModifiers(rawValue: 16), numericPad = EventModifiers(rawValue: 32)
    public static let all = EventModifiers(rawValue: 63)
}

public struct _ViewModifier_Content<Modifier: ViewModifier>: View { public var body: Never { fatalError() } }

public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>
    @ViewBuilder @MainActor func body(content: Content) -> Body
}
extension ModifiedContent: ViewModifier where Content: ViewModifier, Modifier: ViewModifier {
    public func body(content: _ViewModifier_Content<Self>) -> Never { fatalError() }
}

public struct GeometryProxy {
    public var size: CGSize { .zero }
}

public struct GeometryReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
    public var body: Never { fatalError() }
}

public struct Menu<Label: View, Content: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}

public struct GridItem {
    public enum Size { case fixed(CGFloat), flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity), adaptive(minimum: CGFloat, maximum: CGFloat = .infinity) }
    public init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
}

public struct LazyVGrid<Content: View>: View {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {}
    public var body: Never { fatalError() }
}

public struct PinnedScrollableViews: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1), sectionFooters = PinnedScrollableViews(rawValue: 2)
}

// MARK: - UIKit の画面（UIViewController）を入れる

public struct UIViewControllerRepresentableContext<Representable: UIViewControllerRepresentable> {
    public var coordinator: Representable.Coordinator { fatalError() }
}

public protocol UIViewControllerRepresentable: View where Body == Never {
    associatedtype UIViewControllerType: UIViewController
    associatedtype Coordinator = Void
    typealias Context = UIViewControllerRepresentableContext<Self>
    @MainActor func makeUIViewController(context: Context) -> UIViewControllerType
    @MainActor func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context)
    @MainActor func makeCoordinator() -> Coordinator
}
public extension UIViewControllerRepresentable where Coordinator == Void {
    func makeCoordinator() -> Coordinator { () }
}
public extension UIViewControllerRepresentable {
    var body: Never { fatalError() }
}
