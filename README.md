# Shotshelf

A Mac app that files every screenshot you take into the right folder, and gives you a fast place to browse, search and tidy them.

Take a screenshot of a receipt and it lands in `Receipts/Food & Dining/Chipotle`. Screenshot your code editor and it lands in `Development/my-project`. A photo of a friend goes to `Photos/People`. Anything Shotshelf can't place goes to `General`, where Triage lets you file each one with a single key, and Shotshelf learns from what you choose.

- **Private.** Text and images are read on your Mac with Apple's Vision framework. Nothing is uploaded, no accounts, no telemetry.
- **Real folders.** Sorting moves files into ordinary folders, so Finder, Spotlight and backups keep working. Quit Shotshelf and everything stays put.
- **Native and light.** SwiftUI, about 2 MB, no dependencies. Lives in the menu bar and starts at login.

## Features

**Sorting**
- Reads the text in every new screenshot within a few seconds and files it by keyword rules
- Sorts development screenshots by project, by finding your project folders' names on screen
- Spots the app in the menu bar (Terminal, Slack, Figma...) as an extra clue
- Recognizes photos with no text: people, vehicles, food, animals, places, art, charts
- Learns from you: move a screenshot by hand and similar ones follow it next time
- Create `Receipts/Food & Dining/Joe's Pizza` once, and Joe's Pizza receipts go there from then on
- A notification after each sort, with a **Move...** button if it guessed wrong

**Browsing**
- Folder sidebar with counts; drag screenshots onto any folder, or drag them out into other apps
- Search the words inside every screenshot
- Full-screen viewer with filmstrip, shuffle, slideshow, recognized text and Copy Text
- Triage for `General`: `1`-`9` sends the screenshot to a folder, `Space` skips, `Z` undoes
- Undo for every move and trash
- **Option-Command-S** from anywhere opens Shotshelf on your newest screenshot

**Tidying**
- **Expenses:** date, merchant and amount read from every receipt, with a total and CSV export
- **Clean Up:** exact duplicates, look-alikes (several shots of the same page) and old unopened screenshots, reviewed before anything goes to the Trash

## Install

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not needed.

```bash
git clone https://github.com/rikenpatel02/shotshelf.git
cd shotshelf
./build.sh --install          # builds Shotshelf.app and copies it to /Applications
open /Applications/Shotshelf.app
```

On first launch Shotshelf asks where your screenshots should live (default `~/Pictures/Screenshots`) and can point macOS's screenshot location there for you. Allow notifications if you want the Move button after each sort.

`./build.sh --universal` builds for both Apple silicon and Intel.

### Folder permissions and rebuilding

macOS asks once for permission to read protected folders like Desktop or Documents. An unsigned (ad hoc) build counts as a new app every time you rebuild, so macOS asks again. To avoid that, create a local signing identity once; `build.sh` uses it automatically:

1. Open **Keychain Access** > **Certificate Assistant** > **Create a Certificate...**
2. Name it `Shotshelf Local Signing`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.

Or set `SHOTSHELF_SIGN_IDENTITY` to the name of any code-signing identity you already have.

## Configuration

Settings (the menu bar icon > Settings) covers the screenshots folder, your code folders, notifications and login. Everything else lives in `~/.config/shotshelf/config.json`:

```json
{
  "screenshots_dir": "~/Pictures/Screenshots",
  "projects_dirs": ["~/code"],
  "project_ignore": ["archive"],
  "project_generic_names": ["portfolio"],
  "extra_rules": [
    {
      "folder": "Work/Jira",
      "min_score": 3,
      "keywords": ["sprint", "story points", "backlog"],
      "strong": ["jira", "atlassian"],
      "apps": ["jira"]
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `screenshots_dir` | The inbox. New screenshots here are sorted into subfolders of it. |
| `projects_dirs` | Folders holding your code. Any folder with a `package.json`, `.git`, `pyproject.toml`, `Package.swift` and so on becomes a `Development/<project>` destination. Group folders (`clients/acme-site`) keep their group. |
| `project_ignore` | Folder names under `projects_dirs` to skip. |
| `project_generic_names` | Folder names too common to match as words on screen (they are still scanned for projects). |
| `extra_rules` | Your own rules, checked alongside the defaults. Use `"rules"` instead to replace the defaults entirely. |

After editing, choose **Reload** in Settings.

### How a screenshot is sorted

1. Vision reads the text. If there is little text, it also labels what the image shows.
2. Every rule in [`Resources/rules.default.json`](Resources/rules.default.json) is scored:

   | Signal | Points |
   |---|---|
   | keyword found | +1 |
   | strong keyword found (a brand or site name) | +3 |
   | app in the menu bar matches the rule's `apps` | +3 |
   | image label matches the rule's `labels` | +2 |
   | a project name appears on screen | +5 to +8 |
   | known merchant found | +1 |
   | it's a receipt (an amount like `$12.34` plus words like *total*, *tax*, *paid*) | +2, and required by receipt rules |

3. Screenshots you filed by hand are compared to the new one (TF-IDF similarity). A close match suggests the same folder and usually wins.
4. The highest score at or above the rule's `min_score` wins. `{merchant}` and `{project}` in a folder name are filled in. Otherwise: `General`.

Lines that only ever appear next to your browser's bookmarks bar are learned and ignored for project matching, so a bookmark named after a project doesn't drag every browser screenshot into it.

### Default folders

`Receipts/{Food & Dining, Bills & Autopay, Shopping, Travel & Rides, Other}`, `Development/<project>`, `AI Chats`, `Chats & Messages`, `Finance`, `Documents`, `Documents/Charts & Diagrams`, `Social`, `Travel`, `Maps & Places`, `School & Learning`, `Design & Inspiration`, `Photos/{People, Vehicles, Food, Animals, Places}`, `Art & Illustrations`, `General`.

## Keyboard shortcuts

| Where | Keys |
|---|---|
| Anywhere | `Option-Command-S` open Shotshelf on the newest screenshot |
| Grid | arrows select, `Space` open, `M` move, `Delete` trash, `R` auto-sort again, `S` shuffle, `P` slideshow, `T` triage, `Command-A` select all, `Esc` clear |
| Viewer | `Left`/`Right`, `Space` play/pause, `S` shuffle, `T` text, `C` copy text, `M` move, `Delete` trash, `Esc` close |
| Triage | `1`-`9` send, `/` any folder, `Space` skip, `Z` undo, `Esc` done |
| Menus | `Shift-Command-N` new folder, `Shift-Command-E` expenses, `Shift-Command-K` clean up, `Shift-Command-C` copy text, `Command-R` show in Finder |

## Command-line tool

`./build.sh` also builds `build/shotshelf`, which shares the app's sorting code:

```
shotshelf explain FILE          why a screenshot goes where it does
shotshelf sort DIR [--dry-run]  sort every image under DIR (for an old pile of screenshots)
shotshelf stats                 where everything would go with the current rules
shotshelf expenses              receipts as CSV
```

## Where things live

| What | Path |
|---|---|
| Config | `~/.config/shotshelf/config.json` |
| Search index (text, image labels, fingerprints) | `~/Library/Application Support/Shotshelf/` (safe to delete; rebuilt automatically) |

## Project layout

```
Sources/        the app (SwiftUI) and its sorting engine
  Classifier    rules, project discovery, learning from your moves
  Sorter        Vision text + image labels, moving files, keeping the index in sync
  Index         SQLite cache and search
  Library       app state: folders, selection, moves, undo
Resources/      Info.plist, icon, default rules
tools/          command-line tool, icon generator
build.sh        builds the app with swiftc
```

## License

MIT
