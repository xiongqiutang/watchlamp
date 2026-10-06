# Watchlamp

English | [简体中文](README.zh-CN.md)

*A status light for Claude Code on macOS: one lamp per session, readable from across the room.*

Watchlamp puts a floating board on your Mac's screen with one lamp for each Claude Code session, so you can tell which
project is running and which one is waiting for you from across the room. It works with the Claude desktop app (the
Code tab) and with `claude` in the terminal.

![The board with three sessions: running, waiting for you, and done](screenshot.png)

| Lamp (default "Classic" colors) | Meaning | Text under the lamp |
|---|---|---|
| 🟢 Green, with a breathing glow and a light circling the rim | Running | How long the turn has been running and what Claude is doing (e.g. "Command · Run the tests") |
| 🔴 Red with ✋, blinking fast | Waiting for you: a permission prompt, a question or a plan to approve; ❗ when it stopped on an error | How long it has been waiting, and for what |
| ⚫ Off with ✓ | Idle: the turn is done | How long ago it finished and how long it took |

The **edges of every screen can glow** too (all displays at once, and clicks go right through). By default they flash
only while a session is waiting for you; you can also have them light up while Claude works.

It also **plays a sound**: one when Claude needs you, another when a turn is done. A permission prompt you answer within
two seconds stays quiet, and so does a turn you interrupt yourself with Esc.

The interface comes in 12 languages: English, Español, Português (Brasil), Français, Deutsch, Italiano, Русский,
العربية, 日本語, 한국어, 简体中文 and 繁體中文. It follows your Mac's language, or you can pick one under Language in the
menu; in Arabic the board is mirrored.

## Using it

- **Move it**: drag the board anywhere, on your main display or another one; it remembers where you put it. **Move
  board to** in the menu sends it to a particular display in one click.
- **Click a lamp** to switch to the app that session runs in (the Claude desktop app, Terminal, VS Code…).
- **Right-click the board**, or click the **small dot in the menu bar**, for the settings:
  - Lamp size: Small / Medium / Large / X-Large / Huge / Maximum (pick a bigger one if you sit farther away)
  - Layout: Horizontal / Vertical (a horizontal board wraps after 4 lamps in a row)
  - Colors: Classic (working green, waiting red), Your turn (working red, click-me yellow, your turn green, as seen
    from your side of the desk), Color-blind friendly (working blue, waiting orange)
  - Show what it's doing, Screen edge glow, Hide board when there are no sessions, Launch at login
  - Always on top (on by default, and visible over full-screen apps); turned off, the board behaves like an ordinary
    window that other windows can cover, and a click brings it back to the front
  - Sound: when Claude needs you and when a turn is done (the default), only when Claude needs you, or off. Either
    sound can be any macOS alert sound or one of your own in `~/Library/Sounds`. Volume goes from 10% to 400%: above
    100%, alerts play louder than other apps' sounds at the same system volume
  - Demo the three states (12 s, with three sample lamps on the board), Language
  - Check for Updates…; Rate Watchlamp… and Send a Suggestion… (sent from inside the app; approved reviews appear on
    [Watchlamp's page](https://thermport.com/watchlamp/)); Leave a Tip… (opens the Lemon Squeezy checkout in your browser)
- Several sessions in the same project show up as "project #1", "project #2". Hover over a lamp to see its full path.

> Tip: when a MacBook's menu bar is crowded, macOS hides the icons that don't fit behind the notch. If you can't see the
> dot in the menu bar, right-click the board: it opens the same menu.

## Install

1. Download the disk image from [thermport.com/watchlamp](https://thermport.com/watchlamp/) and open it.
2. Drag Watchlamp into the Applications folder, then open it from there.
3. The first time, it asks whether to connect to Claude Code: click **Connect to Claude Code** ("Launch at login" is
   already ticked).

Requires macOS 13 or later, on Apple silicon or Intel. The app is signed with a Developer ID and notarized by Apple, so
it opens without warnings. Haven't installed Claude Code yet? That's fine: once you have, choose **Connect to Claude
Code** from the menu.

- **What connecting does**: it adds Watchlamp's hooks to `~/.claude/settings.json`. The original file is backed up to
  `~/.claude/watchlamp/backups/` first, and only hooks whose command contains `Watchlamp` are added or removed;
  everything else stays as it was.
- **Updating**: quit Watchlamp, drag the new version into Applications to replace the old one, and open it.
- **Uninstalling**: choose **Disconnect from Claude Code** in the menu, quit Watchlamp, and drag it to the Trash.
  Deleting it without disconnecting is fine too: the hooks left behind do nothing when they can't find the app. To
  remove every trace, also delete `~/.claude/watchlamp`.

### Install from source

Requires Xcode or the Command Line Tools (`swiftc`):

```bash
git clone https://github.com/xiongqiutang/watchlamp.git
cd watchlamp
./install.sh     # build → install to ~/Applications/Watchlamp.app → connect to Claude Code → launch
./uninstall.sh   # disconnect from Claude Code, remove the login item, the app and its state files
```

## How it works

```
Claude Code ──hook event (JSON)──▶ Watchlamp hook ──▶ ~/.claude/watchlamp/sessions/<session-id>.json
                                                                                         │ read every 0.5 s
                                     floating board + screen edge glow + menu bar icon ◀─┘
```

- The hooks are registered in `~/.claude/settings.json` for 16 events, including SessionStart, UserPromptSubmit,
  PreToolUse, PostToolUse, PermissionRequest, Notification, Stop, StopFailure and SubagentStart/Stop.
- `Watchlamp hook` takes about 15 ms per call, prints nothing and always exits 0, so it never blocks or changes what
  Claude does.
- The whole app is about 1 MB (with code for both Apple silicon and Intel), and the disk image about 0.6 MB. It uses
  under 1% CPU and about 16 MB of memory (an empty macOS app with just a menu bar icon and one window already takes
  about 12 MB). Alert sounds play in a separate, short-lived process (`Watchlamp play-sound`), so no audio code loads
  into Watchlamp itself; above 100% volume, the system's peak limiter makes them louder without clipping.
- At launch and then once a day, it checks for updates (it reads thermport.com/watchlamp/version.json in a separate,
  short-lived process, so no networking code loads into Watchlamp itself) and shows a notification when there is a new
  version. Otherwise it goes online only when you choose Check for Updates… or send a review or a suggestion.
- When a session's Claude Code process exits, its lamp disappears within 2 seconds; sessions with no activity for 12
  hours are cleaned up as well.
- A lamp stays lit while background subagents or workflows are still running; background shells (a dev server, say)
  don't count as running.

## Known limitations

- After you approve a permission prompt, the lamp switches from waiting to running only when that tool finishes
  (Claude Code has no "approved" event).
- Interrupting with Esc or the stop button sends no Stop event: the board notices the interruption in the session's
  transcript and goes dark up to 2 seconds later.

## Development

```
Sources/                  Swift sources: Hook (events → state), Model, Store, Board (the board), EdgeGlow (screen
                          edges), App (the menu), Chime (when to play a sound), Player (plays it), Forms (the review
                          and suggestion windows), Website (update checks, tips), Connection (connecting to and
                          disconnecting from Claude Code), Lang (languages)
Resources/*.lproj/        the interface text in each language (the keys are the English text, so a missing translation
                          shows the English; selftest.sh checks that every language is complete)
scripts/selftest.sh       runs the state machine on simulated events, then tests connecting, disconnecting and the
                          translations
scripts/devtools.sh       developer commands, not shipped in the app: snapshot renders a board screenshot offscreen
                          (in any language), status lists the sessions
scripts/release.sh        builds a release: Developer ID signing → Apple notarization → disk image → notarizes the disk
                          image too
scripts/RenderIcon.swift  draws the app icon at build time
```

`build.sh` builds for both Apple silicon and Intel. You can also connect or disconnect from the command line:
`Watchlamp.app/Contents/MacOS/Watchlamp connect` (or `disconnect`, or `connection` to show the state).

To release a new version, bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, then run

```bash
NOTARY_PROFILE=<notary profile> scripts/release.sh   # makes dist/Watchlamp-<version>.dmg
```

This needs a "Developer ID Application" certificate in your keychain (if there are several, it picks the one valid
longest, or set `SIGN_ID`) and notary credentials saved with `xcrun notarytool store-credentials <notary profile>`.

---

Watchlamp is an independent open-source project, not affiliated with Anthropic. Claude and Claude Code are trademarks of
Anthropic.
