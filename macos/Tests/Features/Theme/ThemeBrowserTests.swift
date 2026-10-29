import AppKit
import Foundation
import Testing
@testable import Ghostty

// MARK: - Main menu install

@MainActor
@Suite
struct ThemeMenuInstallTests {
    /// A main menu shaped like MainMenu.xib: app, File, View (found by its actions), Window.
    private func makeMainMenu(viewTitle: String = "View", viewActions: Bool = true) -> (NSMenu, NSMenu) {
        let main = NSMenu(title: "Main")
        for title in ["Ghostty", "File", "Edit"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }
        let view = NSMenu(title: viewTitle)
        if viewActions {
            view.addItem(withTitle: "Reset Font Size", action: NSSelectorFromString("resetFontSize:"), keyEquivalent: "")
            view.addItem(withTitle: "Increase Font Size", action: NSSelectorFromString("increaseFontSize:"), keyEquivalent: "")
        } else {
            view.addItem(withTitle: "Something", action: nil, keyEquivalent: "")
        }
        let viewItem = NSMenuItem(title: viewTitle, action: nil, keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.submenu = NSMenu(title: "Window")
        main.addItem(window)
        return (main, view)
    }

    private func themeItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.identifier == ThemeMenu.mainMenuItemIdentifier }
    }

    @Test func installsIntoTheViewMenuOnce() throws {
        let (main, view) = makeMainMenu()
        #expect(ThemeMenu.installMenuItem(into: main))
        #expect(ThemeMenu.installMenuItem(into: main))
        let items = themeItems(view)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.title == "Terminal Theme")
        #expect(item.submenu?.delegate === ThemeMenuBuilder.shared)
        // Nowhere else.
        for other in main.items where other.submenu !== view {
            #expect(themeItems(other.submenu ?? NSMenu()).isEmpty)
        }
    }

    @Test func findsAViewMenuWithALocalizedTitleByItsActions() {
        let (main, view) = makeMainMenu(viewTitle: "Darstellung")
        #expect(ThemeMenu.viewMenu(in: main) === view)
        #expect(ThemeMenu.installMenuItem(into: main))
        #expect(themeItems(view).count == 1)
    }

    @Test func fallsBackToTheViewTitle() {
        let (main, view) = makeMainMenu(viewActions: false)
        #expect(ThemeMenu.viewMenu(in: main) === view)
    }

    @Test func reportsAMissingViewMenu() {
        let (main, _) = makeMainMenu(viewTitle: "Other", viewActions: false)
        #expect(ThemeMenu.viewMenu(in: main) == nil)
        #expect(!ThemeMenu.installMenuItem(into: main))
    }

    @Test func browseShortcutIsControlCommandT() throws {
        func event(_ chars: String, _ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 17) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
            ))
        }
        #expect(ThemeMenu.isBrowseShortcut(try event("t", [.command, .control])))
        #expect(!ThemeMenu.isBrowseShortcut(try event("t", [.command])))
        #expect(!ThemeMenu.isBrowseShortcut(try event("t", [.command, .control, .shift])))
        // Dvorak: the physical T key types "y"; ⌃⌘Y stays free.
        #expect(!ThemeMenu.isBrowseShortcut(try event("y", [.command, .control])))
        // Dvorak's "t" is on another physical key and still matches.
        #expect(ThemeMenu.isBrowseShortcut(try event("t", [.command, .control], keyCode: 40)))
        // Russian: the physical T key types "е"; matched by key code.
        #expect(ThemeMenu.isBrowseShortcut(try event("е", [.command, .control])))
        #expect(!ThemeMenu.isBrowseShortcut(try event("к", [.command, .control], keyCode: 15)))
    }
}

// MARK: - Pins

@Suite
struct ThemePinTests {
    @Test func decodesTheOriginalFormat() {
        let id = UUID()
        #expect(ThemePin(storedEntry: ["theme": id.uuidString, "at": 1.0]) == .theme(id))
        #expect(ThemePin(storedEntry: ["theme": "", "at": 1.0]) == .none)
        #expect(ThemePin(storedEntry: ["theme": "garbage"]) == .none)
        #expect(ThemePin(storedEntry: ["at": 1.0]) == .none)
        #expect(ThemeController.assignment(fromStored: nil) == .automatic)
        #expect(ThemeController.assignment(fromStored: ["theme": id.uuidString]) == .explicit(.theme(id)))
    }

    @Test func roundTripsEveryKind() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for pin in [ThemePin.none, .theme(UUID()), .ghostty("Catppuccin Mocha")] {
            let entry = ThemeController.storedEntry(for: pin, at: date)
            #expect(entry["at"] as? Double == date.timeIntervalSince1970)
            #expect(ThemeController.assignment(fromStored: entry) == .explicit(pin))
            // Everything stored is a property-list type (it goes into UserDefaults).
            #expect(PropertyListSerialization.propertyList(entry, isValidFor: .binary))
        }
    }

    @Test func ghosttyPinsReadAsNoneByOlderVersions() {
        let entry = ThemePin.ghostty("Nord").storedFields
        #expect(entry["theme"] as? String == "")
        #expect(entry["ghostty"] as? String == "Nord")
    }

    @Test(arguments: [
        "", " Nord", "Nord ", "../Nord", "/etc/passwd", "a/b", "a\\b", "~/x", ".hidden",
        "light:Nord,dark:Dracula", "Nord,x", "Nord#1", "Nord\nkeybind=x", "x\u{7}",
        String(repeating: "a", count: 129),
    ])
    func rejectsUnsafeGhosttyNames(_ name: String) {
        #expect(ThemePin.validGhosttyName(name) == nil)
        #expect(ThemePin(storedEntry: ["theme": "", "ghostty": name]) == .none)
    }

    @Test func ghosttyPinAppliesOnlyTheName() {
        let theme = ThemePin.surfaceTheme(forGhosttyName: "Nord")
        #expect(theme.ghosttyTheme == "Nord")
        #expect(theme.background == nil && theme.foreground == nil && theme.accent == nil)
        #expect(!ThemeStore.presets.contains { $0.id == ThemePin.ghosttyThemeId })
        // The applier never emits the name itself; only resolved color args.
        #expect(ThemeApplier.configArgs(for: theme).isEmpty)
    }
}

// MARK: - Browser model

/// A scheduler the test fires by hand.
private final class ManualScheduler {
    private var pending: [(id: Int, work: () -> Void)] = []
    private var nextId = 0

    var count: Int { pending.count }

    var scheduler: ThemeBrowserModel.Scheduler {
        // Strong: the model keeps the scheduler alive even when a test drops it.
        { _, work in
            let id = self.nextId
            self.nextId += 1
            self.pending.append((id, work))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }
    }

    func fire() {
        let due = pending
        pending = []
        due.forEach { $0.work() }
    }
}

@Suite
struct ThemeBrowserModelTests {
    private let nordId = UUID()
    private let greenId = UUID()

    private var entries: [ThemeBrowserModel.Entry] {
        [
            .init(kind: .none, title: "None (use config)"),
            .init(kind: .automatic, title: "Automatic (follow rules)"),
            .init(kind: .theme(greenId), title: "Slimer Green", swatchHex: "#3DDC84"),
            .init(kind: .theme(nordId), title: "Nord, hot cursor"),
            .init(kind: .ghostty("Dracula"), title: "Dracula"),
            .init(kind: .ghostty("Nord"), title: "Nord"),
            .init(kind: .ghostty("Solarized Dark"), title: "Solarized Dark"),
        ]
    }

    private final class Log {
        var previews: [ThemeBrowserModel.Entry.Kind] = []
        var commits: [ThemeBrowserModel.Entry.Kind] = []
        var reverts = 0
    }

    private func makeModel(initial: ThemeBrowserModel.Entry.Kind? = .automatic)
        -> (ThemeBrowserModel, ManualScheduler, Log) {
        let clock = ManualScheduler()
        let log = Log()
        let model = ThemeBrowserModel(entries: entries, initial: initial, scheduler: clock.scheduler)
        model.onPreview = { log.previews.append($0) }
        model.onCommit = { log.commits.append($0) }
        model.onRevert = { log.reverts += 1 }
        return (model, clock, log)
    }

    @Test func startsOnTheCurrentRowWithoutPreviewing() {
        let (model, clock, log) = makeModel(initial: .ghostty("Nord"))
        #expect(model.selection == .ghostty("Nord"))
        #expect(model.selectedIndex == 5)
        #expect(log.previews.isEmpty)
        #expect(clock.count == 0)

        // An initial row that isn't listed selects nothing.
        let (other, _, _) = makeModel(initial: .theme(UUID()))
        #expect(other.selection == nil)
    }

    @Test func arrowsPreviewAndCoalesceToTheLatestRow() {
        let (model, clock, log) = makeModel()
        model.move(by: 1)                     // Slimer Green: previewed at once
        #expect(log.previews == [.theme(greenId)])
        model.move(by: 1)                     // Nord, hot cursor
        model.move(by: 1)                     // Dracula
        model.move(by: 1)                     // Nord
        #expect(log.previews == [.theme(greenId)])  // throttled
        #expect(model.selection == .ghostty("Nord"))
        clock.fire()                          // only the latest goes out
        #expect(log.previews == [.theme(greenId), .ghostty("Nord")])
        clock.fire()                          // nothing new: the throttle goes idle
        #expect(clock.count == 0)
        model.move(by: -1)                    // idle again, so immediate
        #expect(log.previews.last == .ghostty("Dracula"))
    }

    @Test func movingClampsAndStartsFromTheEndsWithNoSelection() {
        let (model, clock, log) = makeModel(initial: nil)
        model.move(by: -1)
        #expect(model.selection == .ghostty("Solarized Dark"))
        clock.fire()
        model.move(by: 5)                     // already last
        #expect(model.selection == .ghostty("Solarized Dark"))
        model.move(by: -100)
        #expect(model.selection == ThemeBrowserModel.Entry.Kind.none)
        clock.fire()
        #expect(log.previews == [.ghostty("Solarized Dark"), ThemeBrowserModel.Entry.Kind.none])

        let (fresh, _, _) = makeModel(initial: nil)
        fresh.move(by: 1)
        #expect(fresh.selection == ThemeBrowserModel.Entry.Kind.none)
    }

    @Test func commitKeepsTheSelectionOnceAndIgnoresLaterCalls() {
        let (model, clock, log) = makeModel()
        model.move(by: 1)
        model.move(by: 1)                     // pending in the throttle
        #expect(model.commit())
        #expect(log.commits == [.theme(nordId)])
        #expect(clock.count == 0)             // the throttle was cancelled
        model.cancel()                        // closing the popover after Enter
        model.move(by: 1)
        model.setQuery("x")
        #expect(!model.commit())
        #expect(log.reverts == 0)
        #expect(log.commits == [.theme(nordId)])
        #expect(log.previews == [.theme(greenId)])
        #expect(model.outcome == .committed(.theme(nordId)))
    }

    @Test func cancelRevertsOnceAndStopsPreviews() {
        let (model, clock, log) = makeModel()
        model.move(by: 1)
        model.move(by: 1)
        model.cancel()
        clock.fire()
        model.cancel()
        model.move(by: 1)
        #expect(log.reverts == 1)
        #expect(log.previews == [.theme(greenId)])
        #expect(log.commits.isEmpty)
        #expect(model.outcome == .reverted)
    }

    @Test func cancelWithoutPreviewStillReverts() {
        let (model, _, log) = makeModel()
        model.cancel()
        #expect(log.reverts == 1)
    }

    @Test func filteringSelectsAndPreviewsTheFirstMatch() {
        let (model, _, log) = makeModel()
        model.setQuery("  NORD ")
        #expect(model.visible.map(\.title) == ["Nord, hot cursor", "Nord"])
        #expect(model.selection == .theme(nordId))
        #expect(log.previews == [.theme(nordId)])

        // The selection survives a filter that still shows it.
        model.setQuery("nord,")
        #expect(model.selection == .theme(nordId))

        // Diacritics and case don't matter.
        model.setQuery("dräcula")
        #expect(model.visible.map(\.title) == ["Dracula"])
    }

    @Test func nothingMatchingMeansEnterDoesNothing() {
        let (model, _, log) = makeModel()
        model.setQuery("zzz")
        #expect(model.visible.isEmpty)
        #expect(model.selectedIndex == nil)
        #expect(!model.commit())
        model.move(by: 1)
        #expect(log.commits.isEmpty && log.previews.isEmpty)
        #expect(!model.isFinished)
    }

    @Test func clickingSelectsVisibleRowsOnly() {
        let (model, _, log) = makeModel()
        model.setQuery("Dracula")
        model.select(.ghostty("Nord"))        // filtered out: ignored
        #expect(model.selection == .ghostty("Dracula"))
        model.setQuery("")
        model.select(.theme(greenId))
        #expect(log.previews.last == .ghostty("Dracula"))  // throttled
        #expect(model.selection == .theme(greenId))
    }

    @Test func newEntriesKeepQueryAndSelection() {
        let (model, _, _) = makeModel(initial: .theme(greenId))
        model.setQuery("s")
        let more = entries + [.init(kind: .ghostty("Seoul256"), title: "Seoul256")]
        model.setEntries(more)
        #expect(model.query == "s")
        #expect(model.selection == .theme(greenId))
        #expect(model.visible.contains { $0.title == "Seoul256" })

        model.setEntries(Array(entries.prefix(2)))
        #expect(model.selection == nil)
    }

    @Test func initialGhosttyRowIsSelectedOnceNamesLoad() {
        let clock = ManualScheduler()
        var previews: [ThemeBrowserModel.Entry.Kind] = []
        // Opens with only None, Automatic and themes.json rows; the pin is a Ghostty name.
        let model = ThemeBrowserModel(entries: Array(entries.prefix(4)), initial: .ghostty("Nord"),
                                      scheduler: clock.scheduler)
        model.onPreview = { previews.append($0) }
        #expect(model.selection == nil)
        model.setEntries(entries)
        #expect(model.selection == .ghostty("Nord"))
        #expect(model.selectedIndex == 5)
        #expect(previews.isEmpty)
        #expect(clock.count == 0)
    }

    @Test func lateNamesDontOverrideARowTheUserChose() {
        let (model, _, log) = makeModel(initial: .ghostty("Nord"))
        model.setEntries(Array(entries.prefix(4)))  // Nord not listed (yet)
        #expect(model.selection == nil)
        model.move(by: 1)
        #expect(model.selection == ThemeBrowserModel.Entry.Kind.none)
        model.setEntries(entries)
        #expect(model.selection == ThemeBrowserModel.Entry.Kind.none)
        #expect(log.previews == [ThemeBrowserModel.Entry.Kind.none])
    }

    @Test func browserRowsListThemesThenValidGhosttyNames() {
        let green = SurfaceTheme(id: greenId, name: "Slimer Green", background: "#0B1A12", accent: "#3DDC84")
        let unnamed = SurfaceTheme(name: "")
        let rows = ThemeBrowser.entries(themes: [green, unnamed], ghosttyNames: ["Nord", "../evil", "light:a,dark:b"])
        #expect(rows.map(\.kind) == [.none, .automatic, .theme(greenId), .theme(unnamed.id), .ghostty("Nord")])
        #expect(rows[2].swatchHex == "#3DDC84")
        #expect(rows[3].title == "Untitled")

        #expect(ThemeBrowser.initialKind(for: .automatic) == .automatic)
        #expect(ThemeBrowser.initialKind(for: .explicit(.none)) == ThemeBrowserModel.Entry.Kind.none)
        #expect(ThemeBrowser.initialKind(for: .explicit(.ghostty("Nord"))) == .ghostty("Nord"))
        #expect(ThemeBrowser.initialKind(for: .explicit(.theme(greenId))) == .theme(greenId))
    }

    @Test func themeNamesSkipUnsafeAndNonRegularFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-theme-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = dir.appendingPathComponent("user", isDirectory: true)
        let bundle = dir.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("adir"), withIntermediateDirectories: true)
        for name in ["zeta", "Alpha", "a,b", "x:y", "#c"] {
            try "background = #000000\n".write(to: user.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        try "".write(to: bundle.appendingPathComponent("Alpha"), atomically: false, encoding: .utf8)
        try "".write(to: bundle.appendingPathComponent("Beta"), atomically: false, encoding: .utf8)
        #expect(GhosttyThemeResolver.themeNames(in: [user, bundle]) == ["Alpha", "Beta", "zeta"])
    }
}
