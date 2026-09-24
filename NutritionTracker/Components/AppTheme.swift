import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(red: 0.12, green: 0.62, blue: 0.43)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let field = Color(uiColor: .tertiarySystemGroupedBackground)
    static let divider = Color.primary.opacity(0.08)
}

struct AppCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(AppTheme.divider, lineWidth: 1))
    }
}

extension View {
    func appCard() -> some View { modifier(AppCard()) }
}

enum AppKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct AppSectionHeading: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}
