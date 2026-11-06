import AppKit
import SwiftUI
import Translation

@MainActor
final class TextResultModel: ObservableObject {
    enum Kind { case ocr, translate }

    let kind: Kind
    @Published var text = ""
    @Published var message: String?
    @Published var busy = true
    @Published var configuration: TranslationSession.Configuration?
    private var sourceLines: [String] = []

    init(kind: Kind) {
        self.kind = kind
        message = "正在识别文字…"
    }

    var title: String { kind == .ocr ? "提取文字" : "翻译" }
    var copyTitle: String { kind == .ocr ? "复制全文" : "复制译文" }
    var footnote: String {
        switch kind {
        case .ocr: return "离线识别"
        case .translate: return Prefs.shared.translateEngine == .apple ? "系统离线翻译 · 译为中文" : "百度翻译 · 译为中文"
        }
    }

    func start(image: CGImage) {
        Task {
            do {
                let lines = try await TextRecognizer.recognize(image)
                if lines.isEmpty {
                    finish(message: "没有识别到文字")
                    return
                }
                if kind == .ocr {
                    text = lines.joined(separator: "\n")
                    finish(message: nil)
                    return
                }
                sourceLines = lines
                message = "正在翻译…"
                switch Prefs.shared.translateEngine {
                case .apple: startAppleTranslation()
                case .baidu: await runBaidu()
                }
            } catch {
                finish(message: "识别失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(message: String?) {
        self.message = message
        busy = false
    }

    private func startAppleTranslation() {
        let toTranslate = sourceLines.filter { !LanguageTools.isChinese($0) }
        if toTranslate.isEmpty {
            text = sourceLines.joined(separator: "\n")
            finish(message: nil)
            return
        }
        let detected = LanguageTools.dominantLanguage(toTranslate.joined(separator: " "))
        let source = detected.map { Locale.Language(identifier: $0.rawValue) }
        configuration = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: "zh-Hans"))
    }

    func runApple(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            var requests: [TranslationSession.Request] = []
            for (i, line) in sourceLines.enumerated() where !LanguageTools.isChinese(line) && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                requests.append(TranslationSession.Request(sourceText: line, clientIdentifier: "\(i)"))
            }
            let responses = try await session.translations(from: requests)
            var out = sourceLines
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), out.indices.contains(i) { out[i] = r.targetText }
            }
            text = out.joined(separator: "\n")
            finish(message: nil)
        } catch {
            finish(message: "离线翻译失败：\(error.localizedDescription)\n\n第一次翻译某种语言时，系统需要联网下载语言包。也可以在「设置 → 翻译」中改用百度翻译。")
        }
    }

    private func runBaidu() async {
        do {
            text = try await BaiduTranslator.translate(lines: sourceLines)
            finish(message: nil)
        } catch {
            finish(message: error.localizedDescription)
        }
    }

    func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

struct TextResultView: View {
    @ObservedObject var model: TextResultModel
    var onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()
            ZStack {
                TextEditor(text: $model.text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if let message = model.message {
                    VStack(spacing: 10) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .allowsHitTesting(false)
                }
            }
            Divider()
            HStack {
                Text(model.footnote).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if copied { Text("已复制").font(.system(size: 12)).foregroundStyle(.secondary) }
                Button(model.copyTitle) {
                    model.copyAll()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(model.text.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 300, minHeight: 240)
        .translationTask(model.configuration) { session in
            await model.runApple(session)
        }
    }
}

/// 提取文字 / 翻译结果面板。两种面板各最多一个。
final class TextResultPanelController: NSObject, NSWindowDelegate {
    private static var panels: [TextResultModel.Kind: TextResultPanelController] = [:]

    private let panel: NSPanel
    private let model: TextResultModel
    private let kind: TextResultModel.Kind

    static func show(image: CGImage, translate: Bool, near rect: CGRect, on screen: NSScreen) {
        MainActor.assumeIsolated {
            let kind: TextResultModel.Kind = translate ? .translate : .ocr
            panels[kind]?.panel.close()
            let c = TextResultPanelController(kind: kind)
            panels[kind] = c
            c.position(near: rect, on: screen)
            c.panel.makeKeyAndOrderFront(nil)
            c.model.start(image: image)
        }
    }

    /// 截图结束后面板保留，但不再压在其他窗口上面。
    static func lowerAll() {
        for c in panels.values { c.panel.level = .floating }
    }

    @MainActor
    private init(kind: TextResultModel.Kind) {
        self.kind = kind
        model = TextResultModel(kind: kind)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 420),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .capturePanel
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TextResultView(model: model, onClose: { [weak panel] in panel?.close() }))
    }

    private func position(near rect: CGRect, on screen: NSScreen) {
        let size = panel.frame.size
        let vf = screen.visibleFrame
        var x: CGFloat
        if rect.maxX + 12 + size.width <= vf.maxX {
            x = rect.maxX + 12
        } else if rect.minX - 12 - size.width >= vf.minX {
            x = rect.minX - 12 - size.width
        } else {
            x = rect.maxX - size.width - 12
        }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        var y = rect.maxY - size.height
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        if Self.panels[kind] === self { Self.panels[kind] = nil }
        CaptureCoordinator.shared.session?.refocus()
    }
}
