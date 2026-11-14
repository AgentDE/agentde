# Local patches to SwiftTerm

Vendored from SwiftTerm v1.20.0 (MIT, https://github.com/migueldeicaza/SwiftTerm). Changes from upstream:

1. **`Package.swift` replaced with a trimmed manifest.** It has only the `SwiftTerm` library target and no dependencies. Upstream depends on `swift-subprocess` (an unstable version, which SwiftPM refuses for a stable-versioned dependency) and `swift-argument-parser`, which only its demo targets use.
2. **`Apple/Metal/Shaders.metal` is a `.copy` resource instead of `.process`.** Processing a `.metal` file needs Xcode's `metal` compiler. As a copied resource, SwiftTerm's existing runtime fallback (`MetalTerminalRenderer.makeLibrary` → `device.makeLibrary(source:)`) compiles it at startup.
3. **The build-info plugin was replaced by a static `Sources/SwiftTerm/SwiftTermBuildInfo.swift`.** The plugin uses SwiftPM APIs that need tools version 6, and it shells out to git.
4. **`MacTerminalView.becomeFirstResponder()` is `open` instead of `public`.** AgentDE subclasses the view to learn when a pane gains focus by mouse click.
5. **Added `Sources/SwiftTerm/ScrollbackText.swift`:** `Terminal.scrollbackLines(last:)`, a public read of the whole buffer as text, which AgentDE's cross-session search uses. The buffer's lines are internal to SwiftTerm.
6. **Everything outside the macOS library was removed:** benchmarks, docs, demo apps, tests, fuzzers, tools, scripts, plugins, the iOS sources, the DocC catalog, GitHub workflows and community files. `LICENSE` and `README.md` are kept.
7. **Scrollback lines are stored compactly.** `BufferLine` keeps a `stored` count and a `tail` cell: cells past `stored` all equal `tail` and aren't kept. `compact()` drops the trailing run of identical cells (usually blanks, at least 16 of them), and every mutating method calls `expand()` first, as do reads of another line's raw cells (`init(from:)`, both `copyFrom`s), so only reads ever see a compacted line. `Terminal.scroll` compacts the row that just moved into scrollback. `CharData.isSameCell(as:)` compares cells field by field. Short lines in a wide terminal kept every column's 24-byte cell before; tests are in AgentDE's `ScrollbackCompactionTests`. `Buffer.resize` compacts the scrollback again at the end, since resizing and reflow expand every line (without it, history went back to full width after the first window or pane resize).

8. **Bare file names are implicit links.** `Terminal.ghosttyImplicitLinkRegex` has a fourth branch for a file name with no folder and a familiar extension (`fig_hours.png`, `report.pdf`); AgentDE resolves it against the tab's folder and below. Tests are in AgentDE's `AuditFixTests`.

To update: copy a new SwiftTerm release over `Sources/SwiftTerm`, then re-apply patches 2–5, 7 and 8.
