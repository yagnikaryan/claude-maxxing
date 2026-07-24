import AppKit
import XCTest
@testable import ClaudeMaxx

/// The Reading submenu is the only way to put anything into the reading list,
/// so "the picker is wired up" is a real correctness property — before this,
/// nothing in the app wrote `cm.reading.urls` at all and the channel could
/// only ever show a blank page.
///
/// Exercises `Menu.readingSubmenu` directly rather than through a `Menu`
/// instance: constructing one creates an `NSStatusItem`, which aborts the
/// process outright in a test runner with no window-server connection.
final class MenuTests: XCTestCase {
    /// Isolated defaults, never `ChannelRegistry`'s shared instance —
    /// otherwise the test would append to whatever reading list the developer
    /// running it actually has.
    private func makeChannel() -> ReadingChannel {
        ReadingChannel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            settings: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    func testSubmenuListsEveryEntryAndChecksTheSelectedOne() {
        let channel = makeChannel()
        let target = NSObject()
        channel.add("https://example.com/one")
        channel.add("/tmp/paper.pdf")
        channel.select(index: 0)

        let entries = Menu.readingSubmenu(for: channel, target: target).items.prefix(2)

        XCTAssertEqual(entries.map(\.title), ["example.com/one", "paper.pdf"])
        XCTAssertEqual(entries.map(\.state), [.on, .off], "the checkmark must follow the selection")
        XCTAssertEqual(
            entries.map { $0.representedObject as? Int }, [0, 1],
            "each item carries the index its action reads back"
        )
        XCTAssertTrue(
            entries.allSatisfy { $0.target === target && $0.action != nil },
            "an item with no target is a menu entry that silently does nothing when clicked"
        )
    }

    /// The two ways to grow the list must be reachable when it's empty —
    /// that's the exact state a new user hits, and the state in which the
    /// channel is otherwise useless.
    func testEmptyListStillOffersBothWaysToAddSomething() {
        let titles = Menu.readingSubmenu(for: makeChannel(), target: NSObject()).items.map(\.title)

        XCTAssertTrue(titles.contains("Add Link…"), "got: \(titles)")
        XCTAssertTrue(titles.contains("Add PDF…"), "got: \(titles)")
        XCTAssertTrue(titles.contains("Nothing added yet"), "the empty state must name itself")
        XCTAssertFalse(
            titles.contains { $0.hasPrefix("Remove") },
            "nothing selected means nothing to remove"
        )
    }

    func testRemoveAppearsOnlyWithSomethingSelected() {
        let channel = makeChannel()
        channel.add("https://example.com/one")

        let titles = Menu.readingSubmenu(for: channel, target: NSObject()).items.map(\.title)
        XCTAssertTrue(titles.contains { $0.hasPrefix("Remove") }, "got: \(titles)")
    }

    /// Long titles are truncated to keep the menu narrow, but the full
    /// destination has to stay visible somewhere — otherwise two links to the
    /// same site become indistinguishable.
    func testLongEntriesAreTruncatedButKeepTheirFullTargetInATooltip() {
        let channel = makeChannel()
        let long = "https://example.com/" + String(repeating: "a", count: 120)
        channel.add(long)

        let item = Menu.readingSubmenu(for: channel, target: NSObject()).items[0]

        XCTAssertLessThan(item.title.count, 50, "a single link must not stretch the menu")
        XCTAssertEqual(item.toolTip, long, "the full URL must still be recoverable")
    }
}
