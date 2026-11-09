import SwiftUI

/// Header chip: PR number with a check summary; click to open, plus a Fix button when checks fail.
struct PullRequestChip: View {
    let pr: PullRequestStatus
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Button { store.openPullRequest(pr) } label: {
                HStack(spacing: 5) {
                    Image(systemName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("#\(pr.number)").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    checks.font(.system(size: 11))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.hover))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondary)
            .help("\(pr.title)\n" + (pr.failing > 0 ? "Failing: \(pr.failingNames.joined(separator: ", "))\n" : "")
                  + "Click to open in \(store.settings.openPullRequestsIn == .graphite ? "Graphite" : "GitHub")")

            if pr.failing > 0 {
                Button { store.fixChecksWithClaude(pr) } label: {
                    Label("Fix with Claude", systemImage: "wand.and.stars").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0xE24B4A))
                .hint("Send the failing checks to this tab's Claude")
            }
        }
    }

    @ViewBuilder private var checks: some View {
        if pr.failing > 0 {
            Label("\(pr.failing)", systemImage: "xmark.circle.fill").foregroundStyle(Color(hex: 0xE24B4A))
        } else if pr.pending > 0 {
            Label("\(pr.pending)", systemImage: "clock").foregroundStyle(Theme.needsYou)
        } else if pr.passing > 0 {
            Label("\(pr.passing)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.working)
        }
    }
}

/// A sidebar tab row's PR mark: the checks' state (✓, a clock, ✗), or the PR glyph when it has no checks.
struct PullRequestBadge: View {
    let pr: PullRequestStatus
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if pr.failing > 0 {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xE24B4A))
            } else if pr.pending > 0 {
                Image(systemName: "clock").foregroundStyle(theme.muted)
            } else if pr.passing > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x1D9E75))
            } else {
                Image(systemName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull").foregroundStyle(theme.muted)
            }
        }
        .font(.system(size: 10))
        .help("#\(pr.number) \(pr.title)" + (pr.failing > 0 ? "\nFailing: \(pr.failingNames.joined(separator: ", "))" : ""))
    }
}
