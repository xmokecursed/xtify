# Changelog
All notable changes to **Xtify** are recorded here, newest first.
---

## 3.3.0 - 2026-11-20

**Feature** - Crash records from Android in the debug info

- The copy debug info button now also includes Android's own record of how the earlier runs ended: crashed, crashed in native code, stopped responding, closed for low memory or closed by the user. Each record has the time, whether the app was in the foreground and how much memory it used. Native crashes and not-responding cases add a short readable part of Android's report.
- Java and Kotlin crashes are written down the moment they happen, so the error and its stack are in the debug info after the app is reopened. The report also lists the phone model and Android version. Android's own records need Android 11 or newer, the crash note works on every version.
- Each log line is now written to the saved file the moment it is logged. Before, the newest fraction of a second was held back for a short time, so a crash right then could lose the very lines that explain it.
- Each saved log now notes the process id, so a run can be matched with Android's record of how it ended.

## 3.2.0 - 2026-11-20

**Feature** - Logs that survive restarts

- The debug log is now saved on the device, so the lines from just before a crash are still there after the app is reopened.
- The copy button now includes this run, the run before it and a short part of the one before that, each marked with the app version and start time.
- The app also records when it goes to the background or comes back, memory warnings and each step of startup. That tells a crash while the app was open apart from Android closing it in the background, and shows where a crash at launch stopped.
- Saved logs are capped: the last 6 runs are kept, each trimmed to its newest part, about 1 MB at most in total. The same line repeated in a row is folded into one.
- Logs stay on the device and are only shared when you press the copy button.

Commits: [`56f6180`](https://github.com/xmokecursed/xtify/commit/56f6180)

## 3.1.0 - 2026-11-19

**Feature** - Update notice

- The app checks whether a newer version is out and shows a "New version available" bar at the top with a link to the download page.
- Android and desktop are checked separately, so each one only hears about its own releases.
- The check runs in the background at launch and again every few hours while the app stays open. It stays silent when there is no connection or the check fails.
- The app version is now 3.1.0, matching this changelog (it still said 1.0.0 before).

Commits: [`6edf92d`](https://github.com/xmokecursed/xtify/commit/6edf92d)

## 3.0.3 - 2026-11-17

**UX fix** - Frosted player bar at every size

- The player bar keeps its blurred, translucent look at every size, with the content drawn on top and a soft fade along the bottom edge instead of a hard cut-off.

Commits: [`06515f8`](https://github.com/xmokecursed/xtify/commit/06515f8)

## 3.0.2 - 2026-11-17

**Fix** - Mobile expanded player fix

- Fixed the expanded player opening blank on mobile after the previous change.

Commits: [`389469b`](https://github.com/xmokecursed/xtify/commit/389469b)

## 3.0.1 - 2026-11-17

**UX fix** - Import card, back button and player bar

- Redesigned the "Import a playlist" card.
- Windows: the drag handle on playlist rows now sits inside the row instead of out of bounds.
- Android back button: closes the expanded player first, goes from Search back to Home, and exits the app from Home.
- Player bar gets a frosted, blurred edge instead of an abrupt cut-off.
- Artist mixes: up to 15 artists (was 6) with 50 songs each (was 20).

Commits: [`13b6244`](https://github.com/xmokecursed/xtify/commit/13b6244)

## 3.0.0 - 2026-11-17

**Major update** - No backend server, playlist import

- The Xtify backend is gone: search, trending, recommendations, the auto queue and artist pages now ask YouTube Music directly, with no API keys. Last.fm is no longer used ("Trending on Last.fm" became "Trending on YouTube Music").
- Import Spotify or YouTube playlists into Xtify's own playlists (Library, under Artists you listen to): any number of playlists, a progress bar and a report of how many songs were imported and how many failed after every import.
- Spotify playlists must be public, and Spotify shares at most 100 songs per playlist link.
- Download a whole playlist (every song) in one go.

Commits: [`0048f3a`](https://github.com/xmokecursed/xtify/commit/0048f3a)

## 2.3.0 - 2026-11-15

**Feature** - Lyrics for downloads

- Downloading a song also fetches its lyrics, keeps them for offline use and writes them into the file tags.
- Fix for the desktop lyrics screen; lyrics cache limit raised from 300 to 1000 songs.

Commits: [`9dff6c7`](https://github.com/xmokecursed/xtify/commit/9dff6c7)

## 2.2.0 - 2026-11-15

**Feature** - Time-synced lyrics

- Lyrics from lrclib.net, highlighted line by line in time with the song (plain text when no synced lyrics exist).
- Loaded only when you ask ("Show lyrics"); full-screen lyrics view; L shortcut on desktop.
- Clear messages for instrumental songs, being offline, a busy service and no lyrics found.

Commits: [`676a0eb`](https://github.com/xmokecursed/xtify/commit/676a0eb)

## 2.1.3 - 2026-11-14

**Fix** - Audio engine crash after an audio format change

- When the sound output fails after an audio format change, Xtify opens a fresh audio engine and resumes the same song from the same position, retrying after 1, 2, 4, 6 and 8 seconds.
- If playback cannot be restored it stops and shows "Playback stopped. Check your sound output or connection"; press play to try again.
- A watchdog checks every 4 seconds for frozen playback, and the engine's own error messages are picked up right away.

Commits: [`5877a8d`](https://github.com/xmokecursed/xtify/commit/5877a8d), [`f7069ca`](https://github.com/xmokecursed/xtify/commit/f7069ca)

## 2.1.2 - 2026-11-13

**UX fix** - Desktop accessibility and UX update

- Minimum window size raised to 920 x 600.
- Crisp Windows-style minimize, maximize, restore and close buttons; resize borders follow the system DPI metrics.
- Home card and Now playing panel no longer animate (less motion); Refresh button moved.
- yt-dlp setup and updates no longer run on desktop.

Commits: [`a068967`](https://github.com/xmokecursed/xtify/commit/a068967)

## 2.1.1 - 2026-11-13

**UX fix** - Custom window frame

- Custom title bar with minimize, maximize/restore and close buttons, a drag area and resizing from every edge (native Windows code).
- Home hero card gains Keep it going, with a Play mix button.

Commits: [`2f3c851`](https://github.com/xmokecursed/xtify/commit/2f3c851)

## 2.1.0 - 2026-11-12

**Feature** - Desktop layout and keyboard shortcuts

- Desktop shell: side navigation (Home, Search, Library, Favourites, Downloads), a Back button and a Refresh button.
- Desktop player bar with shuffle, previous, next, repeat, volume and mute, a queue button with a count and a Now playing panel with Up next.
- Keyboard shortcuts (F1 shows the list): Space play/pause, Ctrl+Left/Right previous/next, Shift+Left/Right seek 10 s, Ctrl+Up/Down volume, M mute, Ctrl+S shuffle, Ctrl+R repeat, Ctrl+D like, Ctrl+K or / search, Ctrl+1/2/3 tabs, Q queue, N Now playing, Esc or Alt+Left back, F5 refresh, media keys.
- Hover highlights; right-click or the Menu key opens song options; Home hero card (Welcome / Jump back in).

Commits: [`43560ad`](https://github.com/xmokecursed/xtify/commit/43560ad)

## 2.0.0 - 2026-11-10

**Major update** - Xtify for Windows

- Xtify now runs on Windows (Flutter Windows runner added).
- Desktop audio through just_audio_media_kit and media_kit_libs_windows_audio.
- Dependency lock file refreshed; Visual Studio and VS Code folders and the default test removed from the repository.

Commits: [`78cc85c`](https://github.com/xmokecursed/xtify/commit/78cc85c), [`4d3c5f8`](https://github.com/xmokecursed/xtify/commit/4d3c5f8), [`cdf95f8`](https://github.com/xmokecursed/xtify/commit/cdf95f8), [`83a72fe`](https://github.com/xmokecursed/xtify/commit/83a72fe), [`72b84a5`](https://github.com/xmokecursed/xtify/commit/72b84a5), [`6bec458`](https://github.com/xmokecursed/xtify/commit/6bec458)

## 1.9.3 - 2026-11-08

**Fix** - New Android app ID

- Application ID and namespace changed from com.example.xtify_app to com.xmokecursed.xtify; MainActivity moved and now extends AudioServiceActivity.
- Android treats this as a different app from earlier builds, so it installs next to them and starts with empty history and playlists.

Commits: [`a48afee`](https://github.com/xmokecursed/xtify/commit/a48afee), [`b8eae92`](https://github.com/xmokecursed/xtify/commit/b8eae92), [`2238c61`](https://github.com/xmokecursed/xtify/commit/2238c61), [`89347ca`](https://github.com/xmokecursed/xtify/commit/89347ca), [`4039269`](https://github.com/xmokecursed/xtify/commit/4039269), [`f717ebd`](https://github.com/xmokecursed/xtify/commit/f717ebd)

## 1.9.2 - 2026-11-08

**Fix** - Release build fix (R8) and code clean-up

- Minification is turned off for library modules in release builds (the R8 build fix).
- Comments removed across the code, Android resources, manifests and pubspec.yaml.

Commits: [`d42dfba`](https://github.com/xmokecursed/xtify/commit/d42dfba), [`ba7528a`](https://github.com/xmokecursed/xtify/commit/ba7528a)

## 1.9.1 - 2026-11-04

**UX fix** - Player and sign-in bar

- The player now works fully while you are signed out; a slim "Sign in to YouTube so more songs play" strip floats above the mini player instead of replacing it.
- The strip disappears after sign-in and is hidden while the player is open.

Commits: [`7ca1c26`](https://github.com/xmokecursed/xtify/commit/7ca1c26)

## 1.9.0 - 2026-11-03

**Feature** - Auto queue modes and Up next

- New Auto queue setting in the player: Similar songs (what YouTube Music suggests, the default) or Same artist (only songs by one artist).
- Same artist follows the artist you searched for, otherwise the main artist of the song.
- Understands songs with several artists ("feat.", "&") and checks YouTube Music before treating a name like "Simon & Garfunkel" as two artists.
- An Up next list in the player.
- Slow or stuck lookups and link checks are retried on a fresh connection after 2 seconds instead of waiting for the first attempt to give up; chunked audio source improvements.

Commits: [`c7c48ac`](https://github.com/xmokecursed/xtify/commit/c7c48ac), [`1980ae5`](https://github.com/xmokecursed/xtify/commit/1980ae5)

## 1.8.6 - 2026-10-31

**Fix** - "Sign in to confirm you're not a bot"

- The direct lookup now opens a visitor session the way yt-dlp does (loads a YouTube page once, keeps the visitor id and cookies), so YouTube no longer takes it for a bot.
- If the direct lookup fails, the song most likely to be tapped falls back to yt-dlp.

Commits: [`f855f07`](https://github.com/xmokecursed/xtify/commit/f855f07)

## 1.8.5 - 2026-10-31

**Fix** - Direct song lookup (faster start)

- Songs are looked up with one direct request to YouTube's player API instead of starting yt-dlp each time (yt-dlp took roughly 6-8 s a song on a phone). yt-dlp stays as the fallback.
- The first three songs of a list are prefetched; the next song's lookup can run in parallel.
- Download progress bar no longer breaks on invalid values.

Commits: [`05f36f5`](https://github.com/xmokecursed/xtify/commit/05f36f5), [`2b6aabb`](https://github.com/xmokecursed/xtify/commit/2b6aabb), [`ca945c1`](https://github.com/xmokecursed/xtify/commit/ca945c1)

## 1.8.4 - 2026-10-30

**Fix** - Smarter song lookups

- yt-dlp version check and update.
- Lookups nobody is waiting for (next song, downloads) queue behind the song you tapped; one yt-dlp lookup at a time.
- HLS/DASH links detected and a link health check added; improvements to the chunked audio source.

Commits: [`fc64a53`](https://github.com/xmokecursed/xtify/commit/fc64a53), [`2e89870`](https://github.com/xmokecursed/xtify/commit/2e89870)

## 1.8.3 - 2026-10-29

**Fix** - Chunked playback

- Songs are fetched from YouTube in small ranged pieces (at most 1 MiB; the size halves after a 403) instead of one long request.

Commits: [`6bb2a49`](https://github.com/xmokecursed/xtify/commit/6bb2a49), [`b67e597`](https://github.com/xmokecursed/xtify/commit/b67e597), [`7dc1c98`](https://github.com/xmokecursed/xtify/commit/7dc1c98), [`3a4d407`](https://github.com/xmokecursed/xtify/commit/3a4d407), [`223832d`](https://github.com/xmokecursed/xtify/commit/223832d)

## 1.8.2 - 2026-10-28

**Fix** - Faster song start, round 1

- yt-dlp: fast clients are tried first, a 12-second cutoff applies after warm-up, socket timeout and retries added.
- Debug log gains stream-header and 403 diagnostics; requests send Range: bytes=0-.
- Cleartext traffic allowed only to the loopback address, for the local playback proxy.

Commits: [`de9fd27`](https://github.com/xmokecursed/xtify/commit/de9fd27), [`472b007`](https://github.com/xmokecursed/xtify/commit/472b007), [`7a1d73c`](https://github.com/xmokecursed/xtify/commit/7a1d73c), [`f87bb58`](https://github.com/xmokecursed/xtify/commit/f87bb58), [`1c64d22`](https://github.com/xmokecursed/xtify/commit/1c64d22), [`84143d0`](https://github.com/xmokecursed/xtify/commit/84143d0), [`b64aee8`](https://github.com/xmokecursed/xtify/commit/b64aee8), [`8602968`](https://github.com/xmokecursed/xtify/commit/8602968), [`61c8b63`](https://github.com/xmokecursed/xtify/commit/61c8b63)

## 1.8.1 - 2026-10-25

**Fix** - Android-only project and build fixes

- Removed the unused iOS, macOS, Linux, Web and Windows folders; the project is Android-only (until the Windows version in 2.0.0).
- Gradle fixes: duplicate properties removed, Gradle 9.3.1 (after trying 8.7 and 9.1), applicationId and minSdk 24 set, minify and resource shrinking turned off for release builds.

Commits: [`e0f9f4e`](https://github.com/xmokecursed/xtify/commit/e0f9f4e), [`4cabfa3`](https://github.com/xmokecursed/xtify/commit/4cabfa3), [`ebb782a`](https://github.com/xmokecursed/xtify/commit/ebb782a), [`676830e`](https://github.com/xmokecursed/xtify/commit/676830e), [`7d29dbd`](https://github.com/xmokecursed/xtify/commit/7d29dbd), [`3549b6b`](https://github.com/xmokecursed/xtify/commit/3549b6b), [`fce1a2f`](https://github.com/xmokecursed/xtify/commit/fce1a2f), [`89d042d`](https://github.com/xmokecursed/xtify/commit/89d042d), [`ab77862`](https://github.com/xmokecursed/xtify/commit/ab77862), [`e09e270`](https://github.com/xmokecursed/xtify/commit/e09e270), [`debd773`](https://github.com/xmokecursed/xtify/commit/debd773), [`1e3115f`](https://github.com/xmokecursed/xtify/commit/1e3115f), [`4c58a88`](https://github.com/xmokecursed/xtify/commit/4c58a88), [`a747fa2`](https://github.com/xmokecursed/xtify/commit/a747fa2), [`6729f2d`](https://github.com/xmokecursed/xtify/commit/6729f2d), [`b72fa96`](https://github.com/xmokecursed/xtify/commit/b72fa96), [`927eff4`](https://github.com/xmokecursed/xtify/commit/927eff4)

## 1.8.0 - 2026-10-25

**Feature** - Undo

- Removing a song from a playlist or from your history shows an Undo button that puts it back in its old place.
- No Undo for Downloads, because a deleted file cannot come back.

Commits: [`b8683cf`](https://github.com/xmokecursed/xtify/commit/b8683cf), [`c54e39e`](https://github.com/xmokecursed/xtify/commit/c54e39e), [`ebd4ba0`](https://github.com/xmokecursed/xtify/commit/ebd4ba0), [`0236308`](https://github.com/xmokecursed/xtify/commit/0236308), [`7bbc548`](https://github.com/xmokecursed/xtify/commit/7bbc548), [`0a123b1`](https://github.com/xmokecursed/xtify/commit/0a123b1)

## 1.7.0 - 2026-10-25

**Feature** - Filter and sort playlists

- Filter box and sort menu on playlist pages, Favourites and Downloads.
- Sort by Custom order, Recently added, Title A-Z or Artist A-Z.

Commits: [`5d018a9`](https://github.com/xmokecursed/xtify/commit/5d018a9)

## 1.6.0 - 2026-10-25

**Feature** - Sign-in expired notice

- When the YouTube sign-in expires, a banner says "Your YouTube sign-in expired. Some songs may not play." with a Sign in again button.

Commits: [`07a9f6e`](https://github.com/xmokecursed/xtify/commit/07a9f6e)

## 1.5.0 - 2026-10-25

**Feature** - Copy debug info

- The Library header gets a "Copy debug info" button: a report with time, platform, connection and sign-in state and recent log lines. Cookies, signed links and tokens are redacted.

Commits: [`c67cf9d`](https://github.com/xmokecursed/xtify/commit/c67cf9d)

## 1.4.4 - 2026-10-25

**Fix** - Repository clean-up

- Removed a misnamed Gradle properties file, a leftover test_app folder, build reports and a stray package-lock.json.
- Trimmed build.gradle.kts and pubspec.yaml.

Commits: [`08c4b5d`](https://github.com/xmokecursed/xtify/commit/08c4b5d), [`7f31b00`](https://github.com/xmokecursed/xtify/commit/7f31b00), [`b36455a`](https://github.com/xmokecursed/xtify/commit/b36455a), [`350f495`](https://github.com/xmokecursed/xtify/commit/350f495), [`e1c4465`](https://github.com/xmokecursed/xtify/commit/e1c4465), [`5c62013`](https://github.com/xmokecursed/xtify/commit/5c62013)

## 1.4.3 - 2026-10-24

**Fix** - Self-healing playback

- Reloads the current song in place when its stream dies (error, expired link, frozen or stuck buffering); play, pause and seek on a dead player recover it.
- The auto queue no longer starts from, or falls back to, unrelated earlier artists.
- Taps are debounced, repeat taps on a loading song are ignored and heart toggles are applied in order.
- Debug banner hidden; screen locked to portrait.

Commits: [`69ba49c`](https://github.com/xmokecursed/xtify/commit/69ba49c), [`f48dac2`](https://github.com/xmokecursed/xtify/commit/f48dac2), [`84936d6`](https://github.com/xmokecursed/xtify/commit/84936d6)

## 1.4.2 - 2026-10-24

**UX fix** - Black-and-white polish and the real app logo

- Real app logo: launcher icons (standard and adaptive), in-app logo, black splash screen and the logo in the Home header.
- Calmer black-and-white theme: navigation bar, page transitions, hairline dividers.
- Player: tap the mini player to open it, thinner progress bar, symmetrical control rows, square artwork.
- Press feedback, fade-ins, animated heart and tab fade; equal-width Play and Shuffle buttons; focus outline on the search box.
- An experimental redesign made earlier the same day ("UX Update", "UX Fix") was rolled back.

Commits: [`bad0633`](https://github.com/xmokecursed/xtify/commit/bad0633), [`94e33a9`](https://github.com/xmokecursed/xtify/commit/94e33a9), [`4e32fea`](https://github.com/xmokecursed/xtify/commit/4e32fea), [`da9f959`](https://github.com/xmokecursed/xtify/commit/da9f959), [`d0e2783`](https://github.com/xmokecursed/xtify/commit/d0e2783)

## 1.4.1 - 2026-10-24

**Fix** - Auto queue and player edge cases

- The auto queue never repeats a song that already played (for example one you queued by hand).
- The player never keeps more than one waiting song and ignores a stale "completed" signal.

Commits: [`6eded8b`](https://github.com/xmokecursed/xtify/commit/6eded8b)

## 1.4.0 - 2026-10-24

**Feature** - Queue, shuffle and repeat, offline mode

- Queue: Play next and Add to queue on any song; reorder, remove or clear; a Next in queue list.
- Shuffle and repeat (off, all, this song).
- Offline mode: an offline banner; with no connection Home shows what can still play, web-based lists are hidden and only downloaded songs play. Cover art of downloaded songs works offline.
- Original on YouTube: open the song on YouTube or copy its link.

Commits: [`e3617d7`](https://github.com/xmokecursed/xtify/commit/e3617d7)

## 1.3.1 - 2026-10-23

**Fix** - Auto queue without artist-less songs

- The auto queue never picks a song that has no artist.

Commits: [`5c783a0`](https://github.com/xmokecursed/xtify/commit/5c783a0)

## 1.3.0 - 2026-10-23

**Feature** - Remove from history, quicker Home refresh

- Remove songs from your listening history.
- Pull-to-refresh on Home returns right away; the lists reload in the background.

Commits: [`09d9ed0`](https://github.com/xmokecursed/xtify/commit/09d9ed0), [`8ddfd40`](https://github.com/xmokecursed/xtify/commit/8ddfd40)

## 1.2.1 - 2026-10-23

**UX fix** - Download progress

- Progress banner and animated progress ring while downloading.
- Live download queue on the Downloads screen and smoother streaming progress.

Commits: [`8c17a28`](https://github.com/xmokecursed/xtify/commit/8c17a28), [`a4b6670`](https://github.com/xmokecursed/xtify/commit/a4b6670)

## 1.2.0 - 2026-10-23

**Feature** - Artist mixes

- The Made for you section on Home now shows a mix for each artist you listen to (up to 6 artists, 20 songs each).
- Open a mix to Play or Shuffle it.

Commits: [`8de35f1`](https://github.com/xmokecursed/xtify/commit/8de35f1)

## 1.1.0 - 2026-10-23

**Feature** - Downloads and offline listening

- Download songs into a folder you choose; tags and cover art are written into the file.
- Downloaded songs collect in a Downloads playlist and play without internet.
- Adds the file_picker and flutter_taglib packages.

Commits: [`bb09989`](https://github.com/xmokecursed/xtify/commit/bb09989), [`fff1931`](https://github.com/xmokecursed/xtify/commit/fff1931), [`d8bbe55`](https://github.com/xmokecursed/xtify/commit/d8bbe55)

## 1.0.0 - 2026-10-23

**First release** - First commit in the repository

- Home: Recently played, Made for you, Your playlists and Explore more (trending on Last.fm).
- Search for songs, artists and playlists, with recent searches and Load more.
- Library with playlists (Play, Shuffle, rename, delete) and Artists you listen to; artist pages show Popular songs and the ones you played.
- Favourites, listening history and the player.
- Auto queue: when your list ends, similar songs keep playing (Last.fm similarity and YouTube Music).
- Songs are streamed through yt-dlp, which the app can update by itself.
- Optional YouTube sign-in inside the app, with cookies refreshed automatically.
- Search, trending and recommendations come from the Xtify backend on Render.

Commits: [`cacdb13`](https://github.com/xmokecursed/xtify/commit/cacdb13), [`752abff`](https://github.com/xmokecursed/xtify/commit/752abff)

---
- **2026-11-17** - Documentation images reorganised (Xtify-player.jpg, Xtify-autoplaylist.jpg), a diagram and Windows screenshots added to the README. ([`47d8e4a`](https://github.com/xmokecursed/xtify/commit/47d8e4a), [`245bda3`](https://github.com/xmokecursed/xtify/commit/245bda3), [`560ce30`](https://github.com/xmokecursed/xtify/commit/560ce30), [`fb8ed15`](https://github.com/xmokecursed/xtify/commit/fb8ed15), [`e43089a`](https://github.com/xmokecursed/xtify/commit/e43089a), [`0e8d0f4`](https://github.com/xmokecursed/xtify/commit/0e8d0f4), [`bebc85d`](https://github.com/xmokecursed/xtify/commit/bebc85d), [`96154a9`](https://github.com/xmokecursed/xtify/commit/96154a9), [`ed17813`](https://github.com/xmokecursed/xtify/commit/ed17813), [`1dc417e`](https://github.com/xmokecursed/xtify/commit/1dc417e), [`da60fea`](https://github.com/xmokecursed/xtify/commit/da60fea), [`7c049d2`](https://github.com/xmokecursed/xtify/commit/7c049d2))
- **2026-11-04** - Screenshots refreshed; README updated. ([`1de58ce`](https://github.com/xmokecursed/xtify/commit/1de58ce), [`aebd127`](https://github.com/xmokecursed/xtify/commit/aebd127), [`c3813d7`](https://github.com/xmokecursed/xtify/commit/c3813d7))
- **2026-10-25** - README rewritten with the feature list; screenshots added. ([`2a66186`](https://github.com/xmokecursed/xtify/commit/2a66186), [`c354ae6`](https://github.com/xmokecursed/xtify/commit/c354ae6), [`2304187`](https://github.com/xmokecursed/xtify/commit/2304187), [`c967a17`](https://github.com/xmokecursed/xtify/commit/c967a17), [`be2df72`](https://github.com/xmokecursed/xtify/commit/be2df72), [`29e6f9a`](https://github.com/xmokecursed/xtify/commit/29e6f9a), [`c05b8c1`](https://github.com/xmokecursed/xtify/commit/c05b8c1), [`731b8bc`](https://github.com/xmokecursed/xtify/commit/731b8bc), [`3c8b84f`](https://github.com/xmokecursed/xtify/commit/3c8b84f))
