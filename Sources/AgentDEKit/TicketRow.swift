import AppKit
import SwiftUI

/// One ticket on a line: its state's color, key and title; click to open it in its tracker.
public struct TicketRow: View {
    let ticket: TicketInfo
    var trailing: AnyView?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    public init(ticket: TicketInfo, trailing: AnyView? = nil) {
        self.ticket = ticket
        self.trailing = trailing
    }

    public var body: some View {
        Button { if let url = URL(string: ticket.url) { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(ticket.colorHex.map { Color(hex: $0) } ?? theme.muted.opacity(0.5)).frame(width: 7, height: 7)
                Text(ticket.identifier).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.muted)
                Text(ticket.title).font(.system(size: 11.5)).foregroundStyle(hovering ? theme.text : theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let priority = Self.priorityMark(ticket.priority) {
                    Text(priority).font(.system(size: 10, weight: .bold)).foregroundStyle(ticket.priority == 1 ? Color(hex: 0xFF6B5E) : theme.muted)
                }
                if let trailing { trailing }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help([ticket.identifier, ticket.state].compactMap { $0 }.joined(separator: " · ") + (ticket.url.isEmpty ? "" : " · open it"))
    }

    /// "!!!" urgent, "!!" high, "!" medium; nothing for low or none.
    public static func priorityMark(_ priority: Int) -> String? {
        switch priority {
        case 1: "!!!"
        case 2: "!!"
        case 3: "!"
        default: nil
        }
    }
}
