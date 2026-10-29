# ShareKeeper

Menu bar app that keeps the SMB shares of other Macs at home mounted. Personal use, macOS only.

## Decisions
- **No own file server or protocol.** macOS File Sharing (SMB + Bonjour `_smb._tcp`) already serves,
  authenticates and encrypts. The gap is that mounts vanish after sleep or a new IP address; this app
  only fills that gap. Rejected: an own FUSE/TCP stack like FileDonkey (CC BY-NC, no auth, ~12k lines)
  and an own WebDAV server.
- **Bonjour URLs** (`smb://Name._smb._tcp.local/Share`), like Finder, so IP changes don't matter.
- **No passwords in the app.** The first mount shows the system login dialog (user ticks "Remember in
  keychain"); automatic remounts use `UIOption=NoUI` and rely on that keychain entry.
- **Unmount from the menu pauses auto-mount** for that share. An eject in Finder is not detected; it
  gets remounted at the next wake, network change or host reappearing.
- Same shape as MiddleTap: one `main.swift`, `build.sh` with `swiftc`, `LSUIElement`, `SMAppService`
  for launch on login, `Logger` subsystem `nl.david.ShareKeeper`.

## Build / run
`./build.sh && open ShareKeeper.app`. Logs: `log stream --predicate 'subsystem == "nl.david.ShareKeeper"'`.

## Open questions
- Whether a NetFS mount shows in the Finder sidebar (Apple forums report it may not).
