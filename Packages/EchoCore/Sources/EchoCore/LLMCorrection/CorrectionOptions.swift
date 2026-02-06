import Foundation

/// Options controlling which correction types are allowed in the Auto Edit pipeline.
public struct CorrectionOptions: Sendable, Equatable {
    public var enableHomophones: Bool
    public var enablePunctuation: Bool
    public var enableFormatting: Bool

    public init(
        enableHomophones: Bool = true,
        enablePunctuation: Bool = true,
        enableFormatting: Bool = true
    ) {
        self.enableHomophones = enableHomophones
        self.enablePunctuation = enablePunctuation
        self.enableFormatting = enableFormatting
    }

    public static let `default` = CorrectionOptions()

    public var isEnabled: Bool {
        enableHomophones || enablePunctuation || enableFormatting
    }

    public var summary: String {
        if enableHomophones && enablePunctuation && enableFormatting {
            return "Homophones, punctuation, formatting"
        }

        var parts: [String] = []
        if enableHomophones { parts.append("homophones") }
        if enablePunctuation { parts.append("punctuation") }
        if enableFormatting { parts.append("formatting") }

        return parts.isEmpty ? "Disabled" : parts.joined(separator: ", ")
    }
}
