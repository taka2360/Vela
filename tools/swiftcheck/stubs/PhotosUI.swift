// PhotosUI の形だけ（写真を選ぶ PhotosPicker。iOS 16）
@_exported import SwiftUI

public struct PHPickerFilter: Equatable {
    public static let images = PHPickerFilter(), videos = PHPickerFilter(), livePhotos = PHPickerFilter()
}

public struct PhotosPickerItem: Equatable, Hashable {
    public enum EncodingDisambiguationPolicy: Equatable { case automatic, current, compatible }
    public func loadTransferable<T: Transferable>(type: T.Type) async throws -> T? { nil }
}

public struct PhotosPicker<Label: View>: View {
    public init(selection: Binding<PhotosPickerItem?>, matching filter: PHPickerFilter? = nil,
                preferredItemEncoding: PhotosPickerItem.EncodingDisambiguationPolicy = .automatic,
                @ViewBuilder label: () -> Label) {}
    public var body: Never { fatalError() }
}
