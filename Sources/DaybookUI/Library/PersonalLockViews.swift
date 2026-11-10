import DaybookDesign
import DaybookKit
import SwiftUI

/// A Personal conversation's page while the lock hides it (`PersonalLock`), on both apps: the lock, "Personal
/// conversation", and Unlock, on paper, where its page would be. The Mac's Personal place shows it with nothing
/// selected, and the Trash's page beside a hidden one.
public struct LockedConversationPage: View {
    private let unlock: () -> Void

    public init(unlock: @escaping () -> Void) {
        self.unlock = unlock
    }

    public var body: some View {
        DaybookEmptyState(title: PersonalLockWords.hiddenTitle, image: .symbol(PersonalLockWords.symbol)) {
            Button(PersonalLockWords.unlock, action: unlock)
                .buttonStyle(.daybookTinted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookPalette.paper)
    }
}

/// What covers the iPhone's app while it isn't in front and the person has unlocked Personal, so the app switcher's
/// picture shows none of it: paper and the mark.
public struct PersonalLockCover: View {
    @Environment(\.daybookDensity) private var density

    public init() {}

    public var body: some View {
        DaybookMark(size: density == .touch ? 72 : 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DaybookPalette.paper)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// Whether the cover shows: the lock is on and unlocked (a locked app shows nothing Personal), and the app isn't
    /// active, as while the app switcher takes its picture.
    @MainActor
    public static func shows(_ lock: PersonalLock, isActive: Bool) -> Bool {
        lock.isRequired && lock.isUnlocked && !isActive
    }
}
