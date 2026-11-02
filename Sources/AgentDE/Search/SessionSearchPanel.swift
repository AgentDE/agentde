import AppKit
import SwiftUI

/// The ⌘⇧F panel: a query field, streamed results grouped by session, keyboard navigation.
struct SessionSearchPanel: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var selection = 0

    var body: some View {
        let search = store.search
        @Bindable var bindable = search
        let flat = search.sections
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(theme.muted)
                    TextField("Search your sessions: prompts, Claude's replies, shell output", text: $bindable.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { if flat.indices.contains(selection) { search.open(flat[selection]) } }
                        .onKeyPress(.downArrow) { move(1, flat.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, flat.count); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: search.query) { _, _ in selection = 0 }
                    if let progress = search.progress {
                        ProgressView().controlSize(.small)
                        Text("\(progress.done)/\(progress.total)").font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                HStack(spacing: 8) {
                    Toggle("Include recent sessions (not open)", isOn: $bindable.includeRecent)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Spacer()
                    if !flat.isEmpty {
                        Text("\(flat.reduce(0) { $0 + $1.total }) matches in \(flat.count) sessions")
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                }
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                Divider().overlay(theme.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(flat.enumerated()), id: \.element.id) { i, section in
                                SearchSectionView(section: section, terms: SearchMatch.terms(search.query),
                                                  selected: i == selection)
                                    .id(i)
                                    .onTapGesture { selection = i; search.open(section) }
                            }
                            if flat.isEmpty, search.progress == nil, SearchMatch.terms(search.query).contains(where: { $0.count >= 2 }) {
                                Text("No matches").font(.system(size: 13)).foregroundStyle(theme.muted).padding(16)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 460)
                    .onChange(of: selection) { _, value in withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(value) } }
                }
            }
            .frame(width: 720)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.window))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .onAppear {
            focused = true
            if !search.query.isEmpty { search.schedule() }
        }
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func close() {
        store.searchOpen = false
        store.focusActiveTerminal()
    }
}

private struct SearchSectionView: View {
    let section: SessionSearch.Section
    let terms: [String]
    let selected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if case .recent = section.source {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10)).foregroundStyle(theme.muted)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(section.color ?? theme.muted).frame(width: 8, height: 8)
                }
                Text(section.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(section.subtitle).font(.system(size: 11.5)).foregroundStyle(theme.muted).lineLimit(1)
                Spacer()
                Text(section.total == 1 ? "1 match" : "\(section.total) matches")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            ForEach(section.hits) { hit in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: hit.role == .you ? "person.fill" : hit.role == .claude ? "sparkle" : "terminal")
                        .font(.system(size: 9.5))
                        .foregroundStyle(hit.role == .claude ? Theme.needsYou : theme.muted)
                        .frame(width: 12)
                    Text(highlighted(hit.snippet))
                        .font(.system(size: 12, design: hit.role == .terminal ? .monospaced : .default))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let time = hit.timestamp {
                        Text(time, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.system(size: 10)).foregroundStyle(theme.muted)
                    }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? theme.selected : .clear))
        .activeOutline(selected, radius: 9)
        .contentShape(Rectangle())
    }

    /// The snippet with each search word bolded on a highlighter tint.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: term, options: .caseInsensitive) {
                attributed[range].foregroundColor = theme.text
                attributed[range].backgroundColor = Theme.needsYou.opacity(0.28)
                searchRange = range.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }
}
