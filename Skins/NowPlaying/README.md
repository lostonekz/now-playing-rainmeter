# Now Playing

A Rainmeter widget that lists the applications playing audio right now, and what each one is
playing. Same look as the AI Usage widget: same palette, card, header and footer, and the same
`Scale` variable.

Each row shows:

- **The app name**, from the exe's description ("Google Chrome", "Spotify").
- **Its volume** in the Windows mixer, as a percentage and a bar. Shows `muted` in amber when the
  app is muted there.
- **What it is playing**, labelled by where the text came from:
  - `Track`: title and artist from the system media controls (Spotify and other players).
  - `Tab`: for browsers, the media title of the playing tab. Without one, the active tab's title.
  - `Media`: a media session with a title but no artist.
  - `Window`: the window title, for apps that publish no media info.

**Click a row** to bring that app to the front. A minimized window is restored. For a Chromium
browser (Chrome, Edge, Brave, Opera, Vivaldi), the click first switches to the tab making the
sound, even if it's in another window or isn't the active tab. Chrome reports only one media
session to Windows, the tab that made sound most recently, so a notification ping in another tab
can take it over. The tab strip's "Audio playing" mark still names the right tab. This relies on
the browser's English UI text. In another UI language, or in Firefox, the click goes to the
window instead.

The green dot next to the title turns red if snapshots stop arriving or the script reports an
error. Hover over it for the reason.

A row stays for `HoldSeconds` (6 s) after its app goes quiet, drawn dim, so pauses don't make it
flicker. "Playing" means the app's peak meter went above -40 dBFS, which is clearly audible.
Near-silent streams don't count.

## How it works

`@Resources\Scripts\Get-NowPlaying.ps1` is one long-running Windows PowerShell 5.1 loop:

1. Lists the Core Audio sessions on every active output device and samples their peak meters
   ten times a second, in compiled C#.
2. Every `RefreshInterval` seconds, groups the sessions by process name (browsers play through
   helper processes and hold one session per device), matches them to the playing media sessions,
   and writes `%APPDATA%\NowPlaying\now.txt`.
3. The skin reads that file every second with WebParser.

`now.txt` is `key=value` lines, not JSON. Titles often contain quotes, and escaped JSON would
break the WebParser regex.

Refreshing the skin starts a new copy that signals the old one to stop, so only one runs. The loop
also exits once Rainmeter closes. A watchdog in the skin restarts it if snapshots stop arriving.

## Settings

Click the gear (or right-click the skin) to change the refresh interval (1 / 2 / 5 / 10 s) and the
size (100-250%). Everything else is in `@Resources\Variables.inc`.

## Limits

- An app shows up only if it plays through its own audio session. Sound routed through another
  app (a virtual mixer such as Voicemod) is listed under that app.
- Six rows. The section header still counts any more beyond that.
- Firefox's media session id doesn't contain its name, so it is mapped by a known id. Other
  browsers with the same quirk fall back to the window title.
- Each click starts a short PowerShell helper (`Focus-App.ps1`), so switching takes about half
  a second.
