import SwiftUI
import SwiftData

/// Router between the Welcome hero (no session) and the active Conversation
/// view. All composer state, submit handlers, and follow-up routing live here
/// so both child views stay dumb.
struct ResearchCanvas: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Binding var query: String

    var body: some View {
        Group {
            // Prefer the user's sidebar selection when it diverges from the
            // live session — clicking a different conversation should switch
            // the canvas to that one even if a live session is still in memory.
            if let id = env.selectedSessionID,
               id != env.live?.sessionID,
               let stored = storedSession(for: id) {
                ConversationView(
                    live: nil,
                    storedSession: stored,
                    query: $query,
                    onSubmit: submit,
                    onFollowUp: followUp,
                    onNewSession: newSession,
                    onCancel: cancel
                )
            } else if let live = env.live {
                ConversationView(
                    live: live,
                    storedSession: nil,
                    query: $query,
                    onSubmit: submit,
                    onFollowUp: followUp,
                    onNewSession: newSession,
                    onCancel: cancel
                )
            } else {
                WelcomeView(
                    query: $query,
                    canFollowUp: false,
                    isWorking: false,
                    onSubmit: submit,
                    onFollowUp: followUp,
                    onNewSession: newSession,
                    onCancel: cancel
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvasBackground)
    }

    @ViewBuilder
    private var canvasBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.background(.regularMaterial)
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }

    // MARK: - Actions

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        env.startResearch(query: q)
        query = ""
    }

    private func followUp() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        env.askFollowUp(query: q)
        query = ""
    }

    private func newSession() {
        env.live = nil
        env.selectedSessionID = nil
        query = ""
    }

    private func cancel() {
        env.cancelLive()
    }

    private func storedSession(for id: UUID?) -> StoredSession? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate<StoredSession> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

// Shared glass-card modifier used by the various inline cards (PlanCard, etc).
extension View {
    @ViewBuilder
    func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
