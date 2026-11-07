# Sidebar global modes

Cockpit's sidebar lists full-detail global modes above the workspaces: Notes,
Remote Desktop, Docker, Agentic Use, Runners, and Mock-ups. At most one mode fills the
detail area at a time; leaving a mode returns to the selected workspace.

## Showing and hiding modes

**Settings > Sidebar** has one switch per mode under **Show in Sidebar**. Every
mode is shown by default.

- The hidden set is stored in the `sidebar.hiddenFeatures` preference as an
  array of mode identifiers. Unrecognized identifiers (for example from a newer
  build) are ignored on read and preserved on write, so switching builds keeps
  each choice.
- Hiding a mode removes its sidebar row and its **View > Toggle …** command,
  which also disables that command's keyboard shortcut.
- Hiding the mode that is showing leaves it immediately and the detail area
  returns to the selected workspace. A mode saved as active but hidden does not
  reopen at launch. Showing a mode never opens it.

## Entry points for a hidden mode

`WorkspaceStore` refuses to enter a hidden mode, so every path that enters a
mode checks visibility in one place:

| Entry point | Behavior while the mode is hidden |
| --- | --- |
| Sidebar row | Not listed. |
| View menu toggle and shortcut (⌘0, ⇧⌘0, ⌃⌘0) | The command is hidden, so its shortcut does not fire. |
| The ⌘0 Notes key monitor in the main window | Passes the key through without toggling Notes. |
| `cockpit://usage` and `cockpit://runners` widget links | Cockpit still comes forward, but the mode does not open. |
| Walkie workspace list and dictation | Remote Desktop is no longer offered as a tab, selecting a saved computer's tab is refused, and dictation is not delivered to a remote screen. |
| Kneeboard/Walkie remote workspace selection | Selecting the Remote Desktop workspace does nothing. |

## Adding a mode

`SidebarFeature` (`apple/Sources/Pilot/SidebarFeature.swift`) is the single
source for mode order, titles, and SF Symbols. The sidebar rows, View menu
toggles, settings switches, and settings search terms all derive from
`SidebarFeature.allCases`. A new mode needs a case there, its `WorkspaceStore`
flag, and the compiler-checked `switch` statements that map between them.
