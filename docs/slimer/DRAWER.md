# Slimer drawer (quick terminal)

The drawer is Ghostty's quick terminal (`toggle_quick_terminal`) with tabs, a
configurable animation, and live position changes. Everything here is macOS
only. Config keys are plain Ghostty keys in your Ghostty config file.

## Suggested config

```ini
# Show the drawer from any app.
keybind = global:cmd+backquote=toggle_quick_terminal

# Where and how big.
quick-terminal-position = right
quick-terminal-size = 45%
quick-terminal-screen = mouse

# One keystroke to stack another terminal inside the current drawer tab.
keybind = cmd+shift+enter=new_split:auto

# Animation.
quick-terminal-animation = slide          # slide | fade | none
quick-terminal-animation-easing = ease-out # ease-in | ease-out | ease-in-out | linear
quick-terminal-animation-duration = 0.15

# Tab strip: auto (only with 2+ tabs), always, never.
quick-terminal-tab-bar = auto
```

## Tabs vs. stacks

The drawer has two ways to hold more than one terminal:

- **Stacks (splits).** `new_split:auto` splits the focused terminal along its
  *larger* dimension. A drawer on the `right` or `left` is tall, so `auto`
  stacks terminals vertically; a drawer on the `top` or `bottom` is wide, so
  `auto` places them side by side. Use `new_split:down` / `new_split:right` to
  force a direction. Stacks are visible at the same time and share the
  drawer's width/height. Move between them with `goto_split:next` (default
  `cmd+]`) or the directional `goto_split:*` bindings; `equalize_splits`
  evens them out.
- **Tabs.** Each tab is its own stack of splits, and only one tab is visible
  at a time. Tabs are for separate contexts (a repo, a server, a long-running
  log) that you switch between rather than watch together.

Both are cheap: switching tabs swaps which split tree the window shows; no
process is restarted and nothing is re-rendered in the background.

## Tab keybindings

The drawer reuses Ghostty's normal tab actions, so the default bindings work
without extra config:

| Action | Default |
| --- | --- |
| `new_tab` | `cmd+t` |
| `close_tab` | `cmd+shift+w` |
| `previous_tab` / `next_tab` | `cmd+shift+[` / `cmd+shift+]` (also `ctrl+shift+tab` / `ctrl+tab`) |
| `goto_tab:N` | `cmd+N` |
| `last_tab` | `cmd+9` |
| `move_tab:N` | unbound by default (e.g. `keybind = cmd+shift+left=move_tab:-1`) |
| `prompt_tab_title` / `set_tab_title:…` | unbound; sets the tab's title |

Clicking a tab selects it; hovering shows its close button; `+` opens a new
tab. The drawer never closes its last tab: `close_tab` (or `close_surface` on
the last split) with a single tab hides the drawer and keeps the shell
running, exactly as upstream does. With two or more tabs, closing the last
split in a tab closes that tab and shows its neighbor.

Closing a tab is undoable (`cmd+z`) for the `undo-timeout` window; the tab's
processes keep running until the undo expires. Split-level undo is dropped
when you switch tabs because Ghostty's split undo assumes a single tree per
window.

## Background tabs

Terminals in tabs you are not looking at keep running. They are marked
unfocused and occluded so libghostty does not render them. If a process in a
background tab exits, that split is removed; if the tab becomes empty it is
removed too, without touching the tab you are looking at. A bell in a
background tab shows a bell icon on its tab. `present_terminal` (for example
clicking a desktop notification) brings the right tab forward.

## Position changes

Changing `quick-terminal-position` and reloading the config takes effect
immediately: a visible drawer is hidden without animation and reappears at
the new edge the next time it is toggled. The cached per-screen frame is
discarded so the new axis gets its configured size.

## Not yet

- Only the selected tab survives app restart (window restoration restores one
  split tree, as upstream does). Background tabs are not persisted.
- `close_other_tabs` and `close_tabs_right` are not wired in the drawer.
- Per-tab colors are a placeholder dot in the strip (Phase 2).
