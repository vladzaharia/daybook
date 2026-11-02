import DaybookDesign
import SwiftUI

/// A Settings sheet, the same on both apps: a grouped form under its title, with Cancel and its one action. On the Mac
/// it's a 420 pt sheet with the title above the form and the buttons at its foot (Esc cancels, Return confirms); on
/// the iPhone, a navigation bar with the title and both buttons. Each app presents it its own way: the Mac's
/// `.sheet`, the iPhone's page sheet.
public struct SettingsFormSheet<Content: View>: View {
    /// A button at the sheet's foot or in its bar.
    public struct Action {
        public var title: String
        public var isEnabled: Bool
        public var perform: @MainActor () -> Void

        public init(_ title: String, isEnabled: Bool = true, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.perform = perform
        }
    }

    private let title: String
    private let cancel: Action?
    private let confirm: Action?
    private let content: Content
    #if os(macOS)
    @State private var contentHeight: CGFloat = 0
    #endif

    /// - Parameters:
    ///   - cancel: Cancel, or nil for a sheet with only its action (which Esc then also takes, on the Mac).
    ///   - confirm: The sheet's one action ("Encrypt", "Add", "Done").
    public init(title: String, cancel: Action?, confirm: Action?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.cancel = cancel
        self.confirm = confirm
        self.content = content()
    }

    /// The sheet's width on the Mac.
    public static var macWidth: CGFloat { 420 }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, DaybookSpacing.s5)
                .padding(.top, DaybookSpacing.s5)
            Form { content }
                .formStyle(.grouped)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in contentHeight = height }
                .scrollDisabled(contentHeight <= Self.tallest)
                .frame(height: contentHeight > 0 ? min(contentHeight, Self.tallest) : nil)
            HStack(spacing: DaybookSpacing.s2) {
                Spacer()
                if let cancel {
                    Button(cancel.title, role: .cancel, action: cancel.perform)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!cancel.isEnabled)
                }
                if let confirm {
                    Button(confirm.title, action: confirm.perform)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!confirm.isEnabled)
                        .background {
                            if cancel == nil {
                                // Esc does what the sheet's one button does. Behind it, it takes no room in the row,
                                // so the button meets the form's edge.
                                Button("", action: confirm.perform)
                                    .keyboardShortcut(.cancelAction)
                                    .disabled(!confirm.isEnabled)
                                    .opacity(0)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
            .padding(.horizontal, DaybookSpacing.s5)
            .padding(.bottom, DaybookSpacing.s5)
        }
        .frame(width: Self.macWidth)
        #else
        if isPushed {
            // Pushed onto Settings' own stack: Back leaves it, so it needs no Cancel.
            form(cancel: nil)
        } else {
            NavigationStack { form(cancel: cancel) }
        }
        #endif
    }

    #if os(iOS)
    @Environment(\.settingsFormIsPushed) private var isPushed

    private func form(cancel: Action?) -> some View {
        Form { content }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancel.title, action: cancel.perform).disabled(!cancel.isEnabled)
                    }
                }
                if let confirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirm.title, action: confirm.perform).disabled(!confirm.isEnabled)
                    }
                }
            }
    }
    #endif

    #if os(macOS)
    /// Past this the form scrolls inside the sheet.
    private static var tallest: CGFloat { 480 }
    #endif
}

#if os(iOS)
extension EnvironmentValues {
    /// A `SettingsFormSheet` pushed onto a navigation stack rather than presented (the iPhone's).
    @Entry public var settingsFormIsPushed = false
}

extension View {
    /// Shows a `SettingsFormSheet` under it as a pushed screen: its title and action in the stack's bar, without Cancel.
    public func settingsFormPushed() -> some View { environment(\.settingsFormIsPushed, true) }
}
#endif
