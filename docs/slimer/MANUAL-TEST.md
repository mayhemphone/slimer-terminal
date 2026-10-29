# Manual test checklist

Everything here builds and passes automated tests, but no session could see the app on screen. These checks need a person. Run them on the Debug build first (`macos/build.nu`, then open `macos/build/Debug/Ghostty.app`), then on Release.

Add this to your Ghostty config (or set it in Settings) before starting:

```
keybind = global:cmd+backquote=toggle_quick_terminal
quick-terminal-position = right
quick-terminal-size = 40%
keybind = cmd+shift+enter=new_split:auto
```

The first global hotkey use asks for Accessibility permission. Grant it in System Settings, Privacy & Security, Accessibility.

## Drawer

- [ ] Cmd+` from another app slides the drawer in from the right. Cmd+` again slides it out and returns focus to that app.
- [ ] Cmd+T in the drawer adds a tab. The tab strip appears. Clicking tabs switches them and the shell keeps running.
- [ ] Cmd+Shift+Enter stacks a terminal vertically. Do it twice for three stacked terminals.
- [ ] Cmd+W on a stacked terminal closes only that one. On a tab's last terminal it closes the tab.
- [ ] `exit` in a background tab removes that tab without showing the drawer.
- [ ] Cmd+N opens a normal window, not attached to the side.
- [ ] Changing `quick-terminal-position` to `left` and reloading moves the drawer without restarting the app.
- [ ] `quick-terminal-animation = fade` and `none` behave as named.
- [ ] Switching macOS between light and dark mode updates background tabs too, if your theme uses `light:...,dark:...`.

## Arrange Panes

Open a normal window and split it into 8 terminals of uneven sizes (mix Cmd+D and Cmd+Shift+D, drag a few dividers). Run something visible in each, e.g. `echo N; top`.

- [ ] Window, Arrange Panes, Even Grid (or Cmd+Ctrl+G) in a wide window gives 2 rows x 4 columns, in the same left-to-right, top-to-bottom order. Row dividers line up across columns. Every shell is still running.
- [ ] Cmd+Z restores the previous layout. Cmd+Shift+Z redoes it.
- [ ] The focused terminal stays focused (typing goes to it) after each item.
- [ ] Equal Widths evens only the column widths; row heights inside columns stay as they were. Equal Heights does the reverse.
- [ ] Columns puts all 8 side by side; Rows stacks all 8. Both are undoable.
- [ ] Equalize All matches Resize Split, Equalize Splits and Cmd+Ctrl+=, and is undoable.
- [ ] Zoom a pane (Window, Zoom Split), then Even Grid: the zoom is cleared and the grid shows.
- [ ] With a single pane, every Arrange Panes item (and Equalize Splits) is greyed out.
- [ ] Command palette: "Arrange Panes: Even Grid" etc. appear only with 2+ panes and work.
- [ ] In the drawer (right side, tall): 4 stacked panes, then Even Grid gives 2 rows x 2 columns; 8 gives 4 rows x 2 columns. Switch tabs and back: layout kept, other tab untouched.

## Status bar and git

- [ ] Each terminal has a thin bar at the bottom with the current directory.
- [ ] In a git repo the bar shows branch, staged/unstaged/untracked counts and ahead/behind, and updates within a second after `git add`, `git commit`, or `git switch`.
- [ ] Clicking the branch opens the popover. Picking an action shows the exact command. Insert types it without running. Run is enabled only at an empty prompt.
- [ ] Run while vim or ssh is in the foreground is disabled.
- [ ] Closing many tabs and windows does not grow memory without bound (Activity Monitor), which confirms the status-bar leak fix.

## Claude

- [ ] The Claude button opens a new tab running `claude` in the current directory. Option-click opens a split.
- [ ] File, Claude has Continue and Resume.

## Workspace

- [ ] The Workspace menu lists Home, Dev and league-view-backend.
- [ ] "Go to" at an empty prompt types `cd` and runs it. With text already typed, or a program running, it opens a new tab instead and your typed text is untouched.
- [ ] The command palette (Cmd+Shift+P) shows "Go to:", "Run:" and "Recent:" entries.
- [ ] Recent directories show up after you `cd` around.

## Themes

- [ ] Tab context menu, Theme: picking a preset recolors only that terminal.
- [ ] "Always use for this folder…" then `cd` into that folder in another tab applies the theme there.
- [ ] Reloading the config (Cmd+Shift+,) keeps per-terminal themes.

## Autocomplete (zsh)

- [ ] Typing `git sw` shows a popup with `switch`. Tab inserts it. Enter without navigating runs what you typed and does not insert anything.
- [ ] Arrow down then Enter inserts the highlighted row without running it.
- [ ] `cd ` then Tab lists folders. `git switch ` then Tab lists branches. `npm run ` lists package.json scripts.
- [ ] Esc hides the popup. In vi mode (`bindkey -v`) Esc also enters normal mode.
- [ ] While composing Japanese or Chinese text with an IME, Enter and arrows go to the IME.
- [ ] Typing `cat` on a file containing fake escape sequences never makes the popup appear.
- [ ] Popup position looks right near the right edge and bottom of the window.

## Settings

- [ ] Cmd+, opens Settings. Back up your Ghostty config first.
- [ ] Changing drawer position, theme or font size takes effect immediately and adds a `# >>> slimer managed` block at the end of your config file. Nothing else in the file changes.
- [ ] Recording a global hotkey that is a common shortcut (Cmd+C) is refused.
- [ ] Advanced shows the managed block, any config errors, and the backup file.

## Release build

- [ ] `macos/build.nu --configuration Release` app launches. Compare launch time and typing feel with stock Ghostty.
