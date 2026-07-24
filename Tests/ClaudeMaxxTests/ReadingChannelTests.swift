import AppKit
import PDFKit
import WebKit
import XCTest
@testable import ClaudeMaxx

/// Captures how a navigation ended. A PDF exposes no DOM to query, so the
/// delegate is the only place "did this actually load" is observable.
private final class NavigationRecorder: NSObject, WKNavigationDelegate {
    @objc dynamic var settled = false
    private(set) var failure: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settled = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error
        settled = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failure = error
        settled = true
    }
}

/// The reading list holds two kinds of thing — web links and local files —
/// and both halves of that had a way to fail silently: a file path that
/// parsed to nil never made it into the list, and a `file://` URL handed to
/// `load(URLRequest:)` produced a blank window with no error anywhere.
final class ReadingChannelTests: XCTestCase {
    private func makeChannel() -> ReadingChannel {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return ReadingChannel(defaults: defaults, settings: settings)
    }

    // MARK: Parsing

    /// The forms a real paste actually arrives in. A bare path has no scheme
    /// and `URL(string:)` returns nil for an unescaped space, so the old
    /// `compactMap(URL.init(string:))` dropped precisely the local files this
    /// channel now exists to open.
    func testNormalizesTheFormsPeopleActuallyPaste() {
        XCTAssertEqual(
            ReadingChannel.normalized("/Users/me/my paper.pdf")?.path,
            "/Users/me/my paper.pdf",
            "an absolute path with a space is a file, not a parse failure"
        )
        XCTAssertEqual(
            ReadingChannel.normalized("file:///Users/me/my paper.pdf")?.path,
            "/Users/me/my paper.pdf",
            "a file:// URL with a raw space must not be dropped"
        )
        XCTAssertEqual(
            ReadingChannel.normalized("file:///Users/me/my%20paper.pdf")?.path,
            "/Users/me/my paper.pdf",
            "the properly-encoded form must decode to the same file"
        )
        XCTAssertEqual(
            ReadingChannel.normalized("~/paper.pdf")?.path,
            NSHomeDirectory() + "/paper.pdf",
            "a tilde path must expand — the webview cannot resolve it itself"
        )
        XCTAssertEqual(
            ReadingChannel.normalized("https://example.com/a")?.absoluteString,
            "https://example.com/a"
        )
        XCTAssertEqual(
            ReadingChannel.normalized("example.com/a")?.absoluteString,
            "https://example.com/a",
            "a scheme-less link is a link, not a relative file path"
        )
    }

    func testRejectsInputItCannotTurnIntoAURL() {
        XCTAssertNil(ReadingChannel.normalized(""))
        XCTAssertNil(ReadingChannel.normalized("   "))
    }

    // MARK: List behavior

    func testAddSelectsWhatWasJustAdded() {
        let channel = makeChannel()
        channel.add("https://example.com/one")
        channel.add("https://example.com/two")

        XCTAssertEqual(channel.urls.count, 2)
        XCTAssertEqual(
            channel.currentURL?.absoluteString, "https://example.com/two",
            "adding something and then not showing it would be a surprise"
        )
    }

    func testAddingSomethingAlreadyInTheListSelectsItInsteadOfDuplicating() {
        let channel = makeChannel()
        channel.add("https://example.com/one")
        channel.add("https://example.com/two")
        channel.add("https://example.com/one")

        XCTAssertEqual(channel.urls.count, 2, "the same link twice is still one entry")
        XCTAssertEqual(channel.currentURL?.absoluteString, "https://example.com/one")
    }

    /// Removing the selected tail entry used to be the case that could leave
    /// `currentIndex` pointing past the end of the list.
    func testRemovingTheSelectedTailEntryKeepsTheSelectionInRange() {
        let channel = makeChannel()
        channel.add("https://example.com/one")
        channel.add("https://example.com/two")
        channel.remove(at: 1)

        XCTAssertEqual(channel.urls.count, 1)
        XCTAssertEqual(channel.currentURL?.absoluteString, "https://example.com/one")
    }

    func testRemovingTheLastEntryLeavesAnEmptyListWithNoSelection() {
        let channel = makeChannel()
        channel.add("https://example.com/one")
        channel.remove(at: 0)

        XCTAssertTrue(channel.urls.isEmpty)
        XCTAssertNil(channel.currentURL, "nothing left to point at")
        XCTAssertEqual(channel.url, ReadingChannel.placeholderURL, "the protocol still needs a URL")
    }

    /// `FeedPanel` decides whether to reload by comparing identities. If two
    /// different articles reported the same one, picking from the menu would
    /// change the selection and keep showing the old page.
    func testContentIdentityChangesWithTheSelection() {
        let channel = makeChannel()
        channel.add("https://example.com/one")
        let first = channel.contentIdentity
        channel.add("https://example.com/two")

        XCTAssertNotEqual(channel.contentIdentity, first)
    }

    // MARK: Loading

    /// The silent-failure regression: WKWebView refuses `file://` through
    /// `load(URLRequest:)` and reports nothing, which presented as the same
    /// blank window an empty list did. Asserted end-to-end against a real
    /// webview rather than by inspecting which method was called.
    func testLocalFileActuallyLoadsIntoTheWebView() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm reading \(UUID().uuidString).html")
        try "<html><body>local</body></html>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let channel = makeChannel()
        channel.add(file.path)
        let webView = WKWebView()
        channel.load(into: webView)

        let loaded = expectation(for: NSPredicate { _, _ in webView.url != nil && !webView.isLoading },
                                 evaluatedWith: webView)
        wait(for: [loaded], timeout: 10)

        XCTAssertEqual(webView.url?.path, file.path, "the file must be what ended up loaded")
        let body = try? awaitJS("document.body.innerText", in: webView)
        XCTAssertEqual(body?.trimmingCharacters(in: .whitespacesAndNewlines), "local")
    }

    /// The claim the whole feature rests on: a local PDF opens in the shared
    /// webview. Asserted through the navigation delegate rather than by
    /// probing the DOM, because a PDF has none — which is exactly why the
    /// scroll-restore script can't reach it either.
    func testLocalPDFNavigatesSuccessfullyRatherThanFailing() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm reading \(UUID().uuidString).pdf")
        try Self.writeOnePagePDF(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let channel = makeChannel()
        channel.add(file.path)
        let webView = WKWebView()
        let recorder = NavigationRecorder()
        webView.navigationDelegate = recorder
        channel.load(into: webView)

        let settled = expectation(for: NSPredicate { _, _ in recorder.settled }, evaluatedWith: recorder)
        wait(for: [settled], timeout: 10)

        XCTAssertNil(recorder.failure, "the PDF must load, not error out")
        XCTAssertEqual(webView.url?.path, file.path)
    }

    /// Minimal one-page PDF, generated rather than checked in so the test
    /// carries no binary fixture.
    private static func writeOnePagePDF(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 200, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 260).fill()
        NSColor.black.setFill()
        NSRect(x: 20, y: 200, width: 160, height: 12).fill()
        image.unlockFocus()

        let document = PDFDocument()
        guard let page = PDFPage(image: image) else {
            throw XCTSkip("could not build a PDF page in this environment")
        }
        document.insert(page, at: 0)
        guard document.write(to: url) else {
            throw XCTSkip("could not write a temporary PDF")
        }
    }

    /// An empty list must explain itself. `about:blank` made an unconfigured
    /// channel indistinguishable from a broken one.
    func testEmptyListShowsAnExplanationRatherThanABlankPage() throws {
        let channel = makeChannel()
        let webView = WKWebView()
        channel.load(into: webView)

        let loaded = expectation(for: NSPredicate { _, _ in !webView.isLoading }, evaluatedWith: webView)
        wait(for: [loaded], timeout: 10)

        let text = try awaitJS("document.body.innerText", in: webView)
        XCTAssertTrue(text.contains("Nothing to read yet"), "got: \(text)")
    }

    /// The list stores paths, so a file that moves leaves a dead entry. Say
    /// which one rather than falling back to a blank window.
    func testMissingFileSaysWhichFileIsGone() throws {
        let channel = makeChannel()
        channel.add("/tmp/definitely-not-here-\(UUID().uuidString).pdf")
        let webView = WKWebView()
        channel.load(into: webView)

        let loaded = expectation(for: NSPredicate { _, _ in !webView.isLoading }, evaluatedWith: webView)
        wait(for: [loaded], timeout: 10)

        let text = try awaitJS("document.body.innerText", in: webView)
        XCTAssertTrue(text.contains("That file has moved"), "got: \(text)")
    }

    // MARK: Helpers

    private func awaitJS(_ script: String, in webView: WKWebView) throws -> String {
        var value: String?
        let done = expectation(description: "js")
        webView.evaluateJavaScript(script) { result, _ in
            value = result as? String
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(value)
    }
}
