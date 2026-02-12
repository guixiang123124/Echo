import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum EchoTheme {
    #if canImport(UIKit)
    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #elseif canImport(AppKit)
    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        let dynamic = NSColor(name: NSColor.Name("EchoDynamic")) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
        return Color(dynamic)
    }
    #endif

    public static let keyboardBackground = dynamicColor(
        light: platformColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1.0),
        dark: platformColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
    )

    public static let keyboardSurface = dynamicColor(
        light: platformColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1.0),
        dark: platformColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1.0)
    )

    public static let keyBackground = dynamicColor(
        light: platformColor(red: 1, green: 1, blue: 1, alpha: 1),
        dark: platformColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1.0)
    )

    public static let keySecondaryBackground = dynamicColor(
        light: platformColor(red: 0.84, green: 0.86, blue: 0.90, alpha: 1.0),
        dark: platformColor(red: 0.26, green: 0.26, blue: 0.30, alpha: 1.0)
    )

    public static let keyShadow = Color.black.opacity(0.12)

    public static let pillBackground = dynamicColor(
        light: platformColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1.0),
        dark: platformColor(red: 0.22, green: 0.22, blue: 0.26, alpha: 1.0)
    )

    public static let pillStroke = dynamicColor(
        light: platformColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1.0),
        dark: platformColor(red: 0.30, green: 0.30, blue: 0.34, alpha: 1.0)
    )

    public static let accent = Color(red: 0.16, green: 0.72, blue: 0.98)
    public static let accentSecondary = Color(red: 0.18, green: 0.84, blue: 0.86)

    #if canImport(UIKit)
    private static func platformColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #elseif canImport(AppKit)
    private static func platformColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}
