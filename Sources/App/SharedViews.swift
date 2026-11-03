import SwiftUI

// MARK: - いくつもの画面で同じ形の部品（シートの見出し など）

/// シートの上の行: 見出し・Spacer・右の部品・閉じるボタン（HStack だけ。外側の padding は呼ぶ側が付ける）。
/// 閉じるボタンの文言（完了・閉じる）と左の余白は、画面ごとに今の値を渡す（0 なら余白なし）
struct SheetHeader<Title: View, Trailing: View>: View {
    let closeLabel: String
    var closeLeading: CGFloat = 0
    let close: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            title()
            Spacer()
            trailing()
            Button(closeLabel) { close() }.padding(.leading, closeLeading)
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(closeLabel: String, closeLeading: CGFloat = 0, close: @escaping () -> Void, @ViewBuilder title: @escaping () -> Title) {
        self.init(closeLabel: closeLabel, closeLeading: closeLeading, close: close, title: title, trailing: { EmptyView() })
    }
}
