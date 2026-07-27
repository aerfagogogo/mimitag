import Foundation

enum VoiceInputProviderIcon: Equatable {
    case asset(String)
    case system(String)
}

/// 语音提供方是设备级偏好。Apple 负责设备端实时转写，
/// Codex 通过用户配置的主机复用现有登录态完成录音转写。
enum VoiceInputProvider: String, CaseIterable, Identifiable {
    static let storageKey = "voice.input.provider"
    static let appleTipAcknowledgedStorageKey = "voice.input.appleTipAcknowledged"

    case codex
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input")
        case .apple:
            return L10n.text("ui.apple_voice_input")
        }
    }

    /// 每个选项直接说明主要取舍，避免用户还要把底部整段说明映射回具体提供方。
    var subtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input_description")
        case .apple:
            return L10n.text("ui.apple_voice_input_description")
        }
    }

    var icon: VoiceInputProviderIcon {
        switch self {
        case .codex:
            // 这里表达的是“录音后转写”能力，不再嵌入第三方品牌图标；
            // 使用系统波形后，也能和设备端的 Siri 标识保持同一套视觉语言。
            return .system("waveform")
        case .apple:
            return .system("siri")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> VoiceInputProvider {
        // 新安装默认复用主机已有的 Codex 登录态；用户主动选择设备端后仍保留该偏好。
        guard let rawValue = defaults.string(forKey: storageKey) else {
            return .codex
        }
        return VoiceInputProvider(rawValue: rawValue) ?? .codex
    }
}
