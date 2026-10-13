import SwiftUI

enum TunoryTheme {
    static let spacing: CGFloat = 16
    static let readingWidth: CGFloat = 760
    static let minimumControlHeight: CGFloat = 44
    static let success = Color.green
    static let warning = Color.orange
    static let failure = Color.red
}

struct TunoryScreen<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TunoryTheme.spacing, content: content)
                .frame(maxWidth: TunoryTheme.readingWidth, alignment: .leading)
                .padding(TunoryTheme.spacing)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("screen.scroll")
        .controlSize(.large)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

struct TunoryNotice: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(message).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TunoryActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12, content: content)
            VStack(alignment: .leading, spacing: 12, content: content)
        }.controlSize(.large)
    }
}
