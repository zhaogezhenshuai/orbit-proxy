import AppKit
import OrbitCore

/// Two-language UI strings. Chinese is the source text; `english` follows `Settings.language`.
enum L10n {
    static var english = false
    static var locale: Locale { Locale(identifier: english ? "en_US" : "zh_Hans") }

    /// "system" means Chinese when the user's first preferred language is any Chinese, else English.
    static func isEnglish(_ setting: String) -> Bool {
        switch setting {
        case "zh": return false
        case "en": return true
        default: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }
}

/// Applies Settings.appearance ("system", "light" or "dark") to every Orbit window.
func applyAppearance(_ setting: String) {
    let a: NSAppearance? = setting == "light" ? NSAppearance(named: .aqua) : setting == "dark" ? NSAppearance(named: .darkAqua) : nil
    NSApp.appearance = a
    for w in NSApp.windows { w.appearance = a }
}

func L(_ zh: String, _ en: String) -> String { L10n.english ? en : zh }

extension ProxyMode {
    var label: String {
        switch self {
        case .rule: return L("规则", "Rule")
        case .global: return L("全局", "Global")
        case .direct: return L("直连", "Direct")
        }
    }
}

extension SubscriptionFormat {
    var label: String {
        switch self {
        case .shareLinks: return L("分享链接列表", "share link list")
        case .clash: return L("Clash 配置", "Clash config")
        case .singBox: return L("sing-box 配置", "sing-box config")
        case .sip008: return L("SIP008 配置", "SIP008 config")
        case .html: return L("网页", "web page")
        case .unknown: return L("未知格式", "unknown format")
        }
    }
}

/// User-facing text for errors raised by OrbitCore.
func describe(_ error: Error) -> String {
    switch error {
    case CoreError.binaryNotFound: return L("找不到 mihomo 内核", "mihomo core not found")
    case CoreError.notReady(let log): return L("内核启动失败：", "Core failed to start: ") + log
    case CoreError.authorizationFailed(let m): return L("管理员授权失败：", "Administrator authorization failed: ") + m
    case SubscriptionError.http(let code): return L("订阅返回 HTTP \(code)", "Subscription returned HTTP \(code)")
    case SubscriptionError.noSource: return L("还没有节点来源", "No node source yet")
    case SubscriptionError.invalidURL: return L("订阅地址无效，只支持以 https:// 开头的地址", "Invalid subscription URL; only https:// URLs are supported")
    case SubscriptionError.noNodes(let format):
        switch format {
        case .html: return L("返回的是网页而不是节点列表，订阅地址可能有误或已失效", "Got a web page instead of a node list; the URL may be wrong or expired")
        case .unknown: return L("无法识别的格式。支持：分享链接（vless:// 等）、Clash YAML、sing-box JSON、SIP008",
                                "Unrecognised format. Supported: share links (vless:// etc.), Clash YAML, sing-box JSON, SIP008")
        default: return L("\(format.label)里没有可用节点", "No usable nodes in the \(format.label)")
        }
    default: return "\(error)"
    }
}
