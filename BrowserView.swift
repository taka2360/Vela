import SwiftUI
import WebKit

// MARK: - 画面: 自作の通信（virtio-net → 小さなルーター）で読んだページを表示するブラウザ
//
// 中身は BrowserModel。ここは見た目だけ

struct WebBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @StateObject private var model = BrowserModel()
    @State private var showLog = true

    var body: some View {
        VStack(spacing: 8) {
            addressBar
            Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            WebBox(webView: model.webView)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            Toggle("通信のログ（virtio-net → ルーター）", isOn: $showLog).font(.caption)
            if showLog { logView }
        }
        .padding()
    }

    private var addressBar: some View {
        HStack {
            Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
            Button { model.webView.goForward() } label: { Image(systemName: "chevron.forward") }
            TextField("アドレス", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit { model.go() }
            Button("開く") { model.go() }.buttonStyle(.borderedProminent)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.logText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(height: 180)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.logText) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
