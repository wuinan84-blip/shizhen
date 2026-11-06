import Foundation
import Vision

/// 离线文字识别（简体中文、英文、中英混排）。
enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    cont.resume(returning: lines(from: request.results ?? []))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private struct Item {
        let text: String
        let minX: CGFloat
        let midY: CGFloat
        let height: CGFloat
    }

    /// 把识别出的文字块按行合并：同一水平线上的块从左到右拼接。
    private static func lines(from observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { o -> Item? in
            guard let t = o.topCandidates(1).first?.string, !t.isEmpty else { return nil }
            let b = o.boundingBox
            return Item(text: t, minX: b.minX, midY: b.midY, height: b.height)
        }.sorted { $0.midY > $1.midY }

        var rows: [[Item]] = []
        for item in items {
            if let last = rows.last?.last, let first = rows.last?.first,
               abs(item.midY - first.midY) < min(item.height, last.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in
            row.sorted { $0.minX < $1.minX }.map(\.text).reduce("") { acc, next in
                guard let a = acc.last, let b = next.first else { return acc + next }
                return acc + (isCJK(a) && isCJK(b) ? "" : " ") + next
            }
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||
            (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
    }
}
