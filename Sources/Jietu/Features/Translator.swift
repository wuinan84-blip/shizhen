import CryptoKit
import Foundation
import NaturalLanguage
import Security

struct TranslateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LanguageTools {
    /// 这一行主要是中文（汉字不少于拉丁字母的一半）。
    static func isChinese(_ line: String) -> Bool {
        var han = 0, latin = 0
        for c in line {
            if TextRecognizer.isCJK(c) { han += 1 } else if c.isLetter { latin += 1 }
        }
        return han > 0 && Double(han) >= Double(latin) / 2
    }

    static func dominantLanguage(_ text: String) -> NLLanguage? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage
    }
}

// MARK: - 钥匙串

enum Keychain {
    private static let service = "com.wuyinan.jietu.baidu"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - 百度通用翻译

enum BaiduTranslator {
    static var appID: String { Keychain.get("appid") ?? "" }
    static var secret: String { Keychain.get("key") ?? "" }

    static func translate(lines: [String]) async throws -> String {
        let appID = self.appID.trimmingCharacters(in: .whitespaces)
        let key = self.secret.trimmingCharacters(in: .whitespaces)
        guard !appID.isEmpty, !key.isEmpty else {
            throw TranslateError(message: "请在「设置 → 翻译」中填写百度翻译的 APP ID 和密钥。")
        }
        var out: [String] = []
        for (i, chunk) in chunks(lines).enumerated() {
            if i > 0 { try await Task.sleep(nanoseconds: 1_100_000_000) }   // 标准版每秒 1 次
            out.append(try await request(chunk, appID: appID, key: key))
        }
        return out.joined(separator: "\n")
    }

    /// 单次请求不超过 6000 字节，按行切分。
    private static func chunks(_ lines: [String]) -> [String] {
        var result: [String] = []
        var current = ""
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.utf8.count > 5000 && !current.isEmpty {
                result.append(current)
                current = line
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func request(_ q: String, appID: String, key: String) async throws -> String {
        let salt = String(Int.random(in: 10000...99999999))
        let sign = Insecure.MD5.hash(data: Data((appID + q + salt + key).utf8)).map { String(format: "%02x", $0) }.joined()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let body = "q=\(enc(q))&from=auto&to=zh&appid=\(enc(appID))&salt=\(salt)&sign=\(sign)"

        var req = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = 15

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw TranslateError(message: "网络连接失败，请检查网络后重试。（\(error.localizedDescription)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateError(message: "百度翻译返回了无法识别的内容。")
        }
        if let code = json["error_code"] {
            let codeString = "\(code)"
            if codeString != "52000" {
                throw TranslateError(message: describe(code: codeString, message: json["error_msg"] as? String ?? ""))
            }
        }
        guard let results = json["trans_result"] as? [[String: Any]] else {
            throw TranslateError(message: "百度翻译没有返回译文。")
        }
        return results.compactMap { $0["dst"] as? String }.joined(separator: "\n")
    }

    static func describe(code: String, message: String) -> String {
        switch code {
        case "52001": return "百度翻译请求超时，请重试。"
        case "52002": return "百度翻译系统错误，请重试。"
        case "52003": return "APP ID 或密钥不正确（未授权用户）。请在「设置 → 翻译」中检查。"
        case "54000": return "请求参数为空，请重试。"
        case "54001": return "签名错误：请在「设置 → 翻译」中检查密钥是否填写正确。"
        case "54003": return "访问频率受限，请稍后再试。"
        case "54004": return "百度翻译账户余额不足（免费额度可能已用完）。请到百度翻译开放平台查看或充值。"
        case "54005": return "长文本请求过于频繁，请稍后再试。"
        case "58000": return "客户端 IP 不在允许范围内，请到百度翻译管理控制台检查 IP 限制。"
        case "58001": return "百度翻译不支持该语言方向。"
        case "58002": return "百度翻译服务已关闭，请到管理控制台开启。"
        case "90107": return "百度翻译认证未通过或未生效，请到管理控制台查看。"
        default: return "百度翻译返回错误 \(code)：\(message)"
        }
    }
}
