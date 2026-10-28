import AppKit
import Testing
@testable import Ghostty

// slimer: unit tests for the quick terminal tab model (selection, insert,
// remove, move and goto index math). Uses MockView from SplitTreeTests so no
// libghostty surface is needed.

struct QuickTerminalTabsTests {
    private typealias Tabs = QuickTerminalTabs<MockView>
    private typealias Tab = QuickTerminalTab<MockView>

    private func makeTabs(_ count: Int, selected: Int = 0) -> (Tabs, [Tab]) {
        let tabs = (0..<count).map { _ in Tab(view: MockView()) }
        return (Tabs(tabs: tabs, selectedIndex: selected), tabs)
    }

    // MARK: Basics

    @Test func emptyHasNoSelection() {
        let tabs = Tabs()
        #expect(tabs.isEmpty)
        #expect(tabs.selected == nil)
        #expect(tabs.index(for: .next) == nil)
        #expect(tabs.neighborIndex(forRemoving: 0) == nil)
        #expect(tabs.movedIndex(from: 0, by: 3) == 0)
    }

    @Test func initClampsSelection() {
        let (tabs, all) = makeTabs(3, selected: 10)
        #expect(tabs.selectedIndex == 2)
        #expect(tabs.selected === all[2])
    }

    @Test func tabFromViewRemembersFocus() {
        let view = MockView()
        let tab = Tab(view: view)
        #expect(tab.focusedSurface === view)
        #expect(tab.contains(view))
        #expect(tab.displayTitle == "👻")
        tab.title = "zsh"
        #expect(tab.displayTitle == "zsh")
        tab.titleOverride = "work"
        #expect(tab.displayTitle == "work")
        tab.titleOverride = ""
        #expect(tab.displayTitle == "zsh")
    }

    @Test func lookupByView() throws {
        let (tabs, all) = makeTabs(3)
        let view = try #require(all[1].surfaceTree.first)
        #expect(tabs.index(containing: view) == 1)
        #expect(tabs.tab(containing: view) === all[1])
        #expect(tabs.contains(view))
        #expect(!tabs.contains(MockView()))
        #expect(tabs.index(of: all[2].id) == 2)
    }

    // MARK: Insert

    @Test func insertIntoEmptySelects() {
        var tabs = Tabs()
        let tab = Tab(view: MockView())
        let index = tabs.insert(tab)
        #expect(index == 0)
        #expect(tabs.count == 1)
        #expect(tabs.selected === tab)
    }

    @Test func insertGoesAfterSelectedAndSelects() {
        var (tabs, all) = makeTabs(3, selected: 0)
        let tab = Tab(view: MockView())
        let index = tabs.insert(tab)
        #expect(index == 1)
        #expect(tabs.tabs.map(\.id) == [all[0].id, tab.id, all[1].id, all[2].id])
        #expect(tabs.selectedIndex == 1)
        #expect(tabs.selected === tab)
    }

    @Test func insertWithoutSelectingBeforeSelectionKeepsSelectedTab() {
        var (tabs, all) = makeTabs(3, selected: 2)
        let tab = Tab(view: MockView())
        tabs.insert(tab, at: 0, select: false)
        #expect(tabs.selectedIndex == 3)
        #expect(tabs.selected === all[2])
    }

    @Test func insertWithoutSelectingAfterSelectionKeepsIndex() {
        var (tabs, all) = makeTabs(3, selected: 1)
        tabs.insert(Tab(view: MockView()), select: false)
        #expect(tabs.selectedIndex == 1)
        #expect(tabs.selected === all[1])
    }

    @Test func insertClampsIndex() {
        var (tabs, _) = makeTabs(2)
        let index = tabs.insert(Tab(view: MockView()), at: 99)
        #expect(index == 2)
        #expect(tabs.selectedIndex == 2)
    }

    // MARK: Select

    @Test func selectByIndexAndID() {
        var (tabs, all) = makeTabs(3)
        #expect(tabs.select(index: 2))
        #expect(tabs.selected === all[2])
        #expect(!tabs.select(index: 3))
        #expect(tabs.selectedIndex == 2)
        #expect(tabs.select(id: all[0].id))
        #expect(tabs.selectedIndex == 0)
        #expect(!tabs.select(id: UUID()))
    }

    // MARK: Remove

    @Test func removeSelectedMiddleSelectsRightNeighbor() {
        var (tabs, all) = makeTabs(3, selected: 1)
        let removed = tabs.remove(at: 1)
        #expect(removed === all[1])
        #expect(tabs.count == 2)
        #expect(tabs.selected === all[2])
        #expect(tabs.selectedIndex == 1)
    }

    @Test func removeSelectedLastSelectsNewLast() {
        var (tabs, all) = makeTabs(3, selected: 2)
        tabs.remove(at: 2)
        #expect(tabs.selectedIndex == 1)
        #expect(tabs.selected === all[1])
    }

    @Test func removeBeforeSelectionShiftsSelection() {
        var (tabs, all) = makeTabs(3, selected: 2)
        tabs.remove(at: 0)
        #expect(tabs.selectedIndex == 1)
        #expect(tabs.selected === all[2])
    }

    @Test func removeAfterSelectionKeepsSelection() {
        var (tabs, all) = makeTabs(3, selected: 0)
        tabs.remove(at: 2)
        #expect(tabs.selectedIndex == 0)
        #expect(tabs.selected === all[0])
    }

    @Test func removeLastRemainingEmpties() {
        var (tabs, _) = makeTabs(1)
        tabs.remove(at: 0)
        #expect(tabs.isEmpty)
        #expect(tabs.selected == nil)
        #expect(tabs.selectedIndex == 0)
    }

    @Test func removeOutOfRangeIsNoop() {
        var (tabs, _) = makeTabs(2)
        #expect(tabs.remove(at: 5) == nil)
        #expect(tabs.remove(id: UUID()) == nil)
        #expect(tabs.count == 2)
    }

    @Test func neighborForRemovingPrefersRight() {
        let (tabs, _) = makeTabs(3)
        #expect(tabs.neighborIndex(forRemoving: 0) == 1)
        #expect(tabs.neighborIndex(forRemoving: 1) == 2)
        #expect(tabs.neighborIndex(forRemoving: 2) == 1)
        let (single, _) = makeTabs(1)
        #expect(single.neighborIndex(forRemoving: 0) == nil)
    }

    // MARK: Move

    @Test func moveKeepsSelectedTab() {
        var (tabs, all) = makeTabs(4, selected: 1)
        tabs.move(from: 1, to: 3)
        #expect(tabs.tabs.map(\.id) == [all[0].id, all[2].id, all[3].id, all[1].id])
        #expect(tabs.selectedIndex == 3)
        #expect(tabs.selected === all[1])
    }

    @Test func moveOtherTabAdjustsSelectedIndex() {
        var (tabs, all) = makeTabs(3, selected: 2)
        tabs.move(from: 0, to: 2)
        #expect(tabs.tabs.map(\.id) == [all[1].id, all[2].id, all[0].id])
        #expect(tabs.selected === all[2])
        #expect(tabs.selectedIndex == 1)
    }

    @Test func moveOutOfRangeOrSameIsNoop() {
        var (tabs, all) = makeTabs(2)
        tabs.move(from: 0, to: 0)
        tabs.move(from: 0, to: 5)
        tabs.move(from: -1, to: 1)
        #expect(tabs.tabs.map(\.id) == all.map(\.id))
    }

    @Test func movedIndexClamps() {
        let (tabs, _) = makeTabs(3)
        #expect(tabs.movedIndex(from: 1, by: 1) == 2)
        #expect(tabs.movedIndex(from: 1, by: -1) == 0)
        #expect(tabs.movedIndex(from: 1, by: 10) == 2)
        #expect(tabs.movedIndex(from: 1, by: -10) == 0)
        #expect(tabs.movedIndex(from: 2, by: 1) == 2)
    }

    // MARK: Goto

    @Test func gotoPreviousAndNextWrap() {
        let (first, _) = makeTabs(3, selected: 0)
        #expect(first.index(for: .previous) == 2)
        #expect(first.index(for: .next) == 1)

        let (last, _) = makeTabs(3, selected: 2)
        #expect(last.index(for: .previous) == 1)
        #expect(last.index(for: .next) == 0)
    }

    @Test func gotoLast() {
        let (tabs, _) = makeTabs(3, selected: 0)
        #expect(tabs.index(for: .last) == 2)
    }

    @Test func gotoAbsoluteIsOneIndexedAndClamps() {
        let (tabs, _) = makeTabs(3)
        #expect(tabs.index(for: .absolute(1)) == 0)
        #expect(tabs.index(for: .absolute(3)) == 2)
        #expect(tabs.index(for: .absolute(9)) == 2)
        #expect(tabs.index(for: .absolute(0)) == nil)
        #expect(tabs.index(for: .absolute(-1)) == nil)
    }

    @Test func gotoSingleTab() {
        let (tabs, _) = makeTabs(1)
        #expect(tabs.index(for: .previous) == 0)
        #expect(tabs.index(for: .next) == 0)
        #expect(tabs.index(for: .last) == 0)
    }

    // MARK: Tab bar visibility

    @Test func tabBarVisibility() {
        #expect(!QuickTerminalTabBar.auto.isVisible(tabCount: 1))
        #expect(QuickTerminalTabBar.auto.isVisible(tabCount: 2))
        #expect(QuickTerminalTabBar.always.isVisible(tabCount: 1))
        #expect(!QuickTerminalTabBar.never.isVisible(tabCount: 5))
    }

    @Test func tabBarModelPublishesOnlyOnChange() {
        let model = QuickTerminalTabBarModel()
        let id = UUID()
        let item = QuickTerminalTabBarModel.Item(id: id, title: "zsh", bell: false, color: nil)
        model.update(items: [item], selectedID: id)
        #expect(model.items == [item])
        #expect(model.selectedID == id)
        #expect(!model.isVisible)
        model.update(visibility: .always)
        #expect(model.isVisible)
    }
}
