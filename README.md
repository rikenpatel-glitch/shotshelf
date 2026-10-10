# Shotshelf

Auto-sort your macOS screenshots into folders, and browse them in a fast, good-looking local viewer.

Take a screenshot of a receipt and it lands in `Receipts/Food & Dining/Chipotle`. Screenshot your code editor and it lands in `Development/my-project`. Anything Shotshelf can't place goes to `General`, where a one-key triage mode lets you send each one to the right folder in a second.

- **Private by design.** Text is read on your Mac with Apple's Vision framework. Nothing is uploaded, no API keys, no telemetry.
- **Zero dependencies.** Python standard library, one Swift file, one HTML file. No `pip install`, no `npm install`.
- **Real folders.** Sorting moves files into ordinary folders, so Finder, Spotlight and backups all keep working. Delete Shotshelf and your folders stay.
- **Learns from you.** Create `Receipts/Food & Dining/Joe's Pizza` once, and future Joe's Pizza receipts go there automatically. Same for project folders.

## The viewer

- Folder tree with counts, drag and drop screenshots onto any folder
- Full-text search over the words inside every screenshot
- Lightbox with filmstrip, shuffle, slideshow and a recognized-text panel
- Triage mode for `General`: press `1`-`9` to send a screenshot to a folder, `Space` to skip, `Z` to undo
- Multi-select (`Cmd`-click, `Shift`-click, `Cmd+A`), move with `M`, re-run auto-sort, reveal in Finder, move to Trash
- Undo on every move, light and dark themes, respects reduced motion

## Requirements

- macOS 12 or later
- Python 3.9+ (`/usr/bin/python3` works)
- Xcode Command Line Tools for the Swift compiler: `xcode-select --install`

## Install

```bash
git clone https://github.com/<you>/shotshelf.git
cd shotshelf
python3 shotshelf.py init        # writes ~/.config/shotshelf/config.json
python3 shotshelf.py install     # starts the watcher + viewer, and at every login
open http://127.0.0.1:8765
```

`install` registers two LaunchAgents in `~/Library/LaunchAgents`:

| Job | What it does |
|---|---|
| `com.shotshelf.watch` | Runs `shotshelf.py sort` whenever a file appears in your screenshots folder |
| `com.shotshelf.serve` | Keeps the viewer running on `127.0.0.1:8765` (localhost only) |

Logs go to `~/Library/Logs/shotshelf.log`. Remove everything with `python3 shotshelf.py uninstall`; your screenshots are never touched.

### If your screenshots are on the Desktop or in Documents

macOS protects those folders. The first time the background job runs, macOS may block it silently. Fix it once in **System Settings > Privacy & Security > Files and Folders** (or **Full Disk Access**) by allowing the Python shown in the log. The simplest option is to save screenshots somewhere unprotected:

```bash
mkdir -p ~/Pictures/Screenshots
defaults write com.apple.screencapture location ~/Pictures/Screenshots
```

Then set `"screenshots_dir": "~/Pictures/Screenshots"` in your config and run `install` again.

## Sort what you already have

```bash
python3 shotshelf.py sort --path ~/Desktop/Old\ Screenshots --dry-run   # preview
python3 shotshelf.py sort --path ~/Desktop/Old\ Screenshots             # move them
```

Text recognition takes about 1-2 seconds per screenshot. Results are cached by file content, so nothing is read twice.

## Configuration

`~/.config/shotshelf/config.json`:

```json
{
  "screenshots_dir": "~/Desktop/Screenshots",
  "projects_dirs": ["~/code"],
  "project_ignore": ["archive"],
  "project_generic_names": ["portfolio"],
  "port": 8765,
  "extra_rules": [
    {
      "folder": "Work/Jira",
      "min_score": 3,
      "keywords": ["sprint", "story points", "backlog"],
      "strong": ["jira", "atlassian"]
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `screenshots_dir` | The inbox. New screenshots here get sorted into subfolders of it. |
| `projects_dirs` | Folders containing your code projects. Any folder with a `package.json`, `.git`, `pyproject.toml`, etc. becomes a `Development/<project>` destination, matched by its name appearing in the screenshot. Group folders (like `clients/acme-site`) are kept as `Development/clients/acme-site`. |
| `project_ignore` | Folder names under `projects_dirs` to skip entirely. |
| `project_generic_names` | Folder names that are still scanned for projects but are too common to match as words (for example `portfolio`). |
| `extra_rules` | Your own rules, checked alongside the defaults. Add `"rules": [...]` instead to replace the defaults completely. |

### How a screenshot is sorted

1. Apple Vision reads the text.
2. Every rule in [`rules.default.json`](rules.default.json) is scored: `+1` per keyword found, `+3` per strong keyword, `+4` when a project name matches. Receipt rules only apply when the text looks like a receipt (an amount like `$12.34` plus words like *total*, *tax*, *paid*).
3. The highest score at or above the rule's `min_score` wins. `{merchant}` and `{project}` in a folder name are filled in from what matched.
4. If nothing qualifies, the file goes to `General`.

To see why a file went where it did:

```bash
python3 shotshelf.py explain ~/Desktop/Screenshots/General/Screenshot\ 2026-05-01\ at\ 9.41.12\ AM.png
```

### Default folders

`Receipts/{Food & Dining, Bills & Autopay, Shopping, Travel & Rides, Other}`, `Development/<project>`, `AI Chats`, `Chats & Messages`, `Finance`, `Documents`, `Social`, `Travel`, `Maps & Places`, `Design & Inspiration`, `General`.

## Keyboard shortcuts

| Where | Keys |
|---|---|
| Grid | `/` search, `Cmd+A` select all, `M` move, `Delete` trash, `S` shuffle, `P` slideshow, `T` triage, `Esc` clear |
| Lightbox | `Left`/`Right` navigate, `Space` play/pause, `S` shuffle, `T` text, `M` move, `Delete` trash, `Esc` close |
| Triage | `1`-`9` send, `/` any folder, `Space` skip, `Z` undo, `Esc` done |
| Move dialog | type to filter, type a new path to create it, `Enter` to move |

## Commands

```
shotshelf.py init                 create the config file
shotshelf.py sort                 sort new screenshots in the inbox
shotshelf.py sort --path DIR      sort every image under DIR (add --dry-run to preview)
shotshelf.py explain FILE         show the scores behind a decision
shotshelf.py index                read text of every screenshot for search
shotshelf.py serve [--open]       run the viewer in the foreground
shotshelf.py install / uninstall  manage the background jobs
```

## Where things live

| What | Path |
|---|---|
| Config | `~/.config/shotshelf/config.json` |
| Search index and thumbnails | `~/Library/Application Support/Shotshelf/` (safe to delete; rebuilt automatically) |
| Log | `~/Library/Logs/shotshelf.log` |

## Security

The viewer binds to `127.0.0.1` only, rejects requests whose `Host` isn't localhost (DNS-rebinding protection), requires a custom header on every write (so other websites can't trigger moves), and refuses any path outside your screenshots folder. Trash moves files to `~/.Trash`, so they can be recovered.

## License

MIT
