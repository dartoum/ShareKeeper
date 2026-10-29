# ShareKeeper

Menu bar app for my own Macs: one folder, `~/ShareKeeper`, with the same contents on every paired Mac.
Put something in it on one Mac and it shows up on the other; nothing else is shared. Personal use, macOS
only. One Mac is restricted with File Sharing off there, so this does not use File Sharing.

## How it works
- **Own link between Macs** (`Sources/Core`): Bonjour `_sharekeeper._tcp`, then a TCP connection that is
  mutually authenticated and encrypted by our own handshake (`Crypto.swift`): X25519 static + ephemeral
  keys, HKDF, ChaCha20-Poly1305 frames. Request/response RPC with a JSON header and raw file bytes (`Wire.swift`).
- **Either Mac may dial, one link serves both directions.** Frames are tagged request/response; a paired Mac
  that dials us has its connection adopted by our `RemoteClient` (`PeerListener.adopt`). Needed in practice:
  the other Mac sees us on Bonjour, we do not see it. If both dial at once, both keep the link dialed by
  the Mac with the smaller id; otherwise a fresh link replaces an older one.
- **Pairing** is once per pair: one Mac picks the other under "Pair a New Mac", both show a six digit code
  (numeric comparison with commit/reveal, so a man in the middle cannot grind matching keys), the user
  confirms on both. That is the only setup step.
- **Sync** (`Sync.swift`): three-way, per pair, driven by the Mac with the smaller id (the other only answers
  and sends "changed" when its folder changes). Base state per peer in
  `~/Library/Application Support/ShareKeeper/sync-<peer id>.json`.
  New/changed on one side → copied (temp name, then rename, mtime carried over). Deleted on one side and
  untouched on the other → the other side's copy goes to the Trash. Changed on both → both kept, the other
  Mac's version as "name (Other Mac).ext". A folder deleted on one side keeps whatever was changed in it on
  the other. Finder's `.DS_Store`, `._*` etc. are never synced; symlinks and other volumes are skipped.
- **Triggers**: a 3 s scan of `~/ShareKeeper` for changes, the peer's "changed" nudge, link up, and every 20 s.
- **Confinement** (`FileServer.swift`), on the Mac that owns the files: no `..`, symlinks only followed when
  they stay inside the folder, `scan` does not follow them at all.

## Decisions
- Sync, not a mounted network drive (0.2 mounted the other Mac via a loopback NFS server). Wanted: one
  ordinary folder in home with only the shared things in it, on both Macs. Sync gives exactly that, keeps
  working when the other Mac is off, and has no NFS client quirks. Cost: files exist on both Macs.
- Rejected: macOS File Sharing/SMB ((not available)), FUSE (driver install), WebDAV, forking Deskflow (it removed
  file transfer on purpose; server/client model), FileDonkey's code (CC BY-NC, no auth). Nothing copied.
- Deletes go to the Trash, never straight away: a sync bug must not be able to lose files.
- The private key is a 0600 file in `~/Library/Application Support/ShareKeeper`, not the keychain: an
  ad-hoc signed rebuild would make the keychain prompt again.
- At launch, 0.2 leftovers are cleaned up: loopback NFS mounts under `~/ShareKeeper` are unmounted and
  their empty folders removed, and `~/ShareKeeper Drop` is moved into `~/ShareKeeper`.

## Build / test
- `./build.sh && open ShareKeeper.app`; `./dmg.sh` makes `ShareKeeper-<version>.dmg`.
  Logs: `/usr/bin/log stream --predicate 'subsystem == "nl.david.ShareKeeper"'` (plain `log` is a zsh builtin).
- `Tests/run.sh`: both sides in one process (confinement, pairing, strangers refused, link both ways,
  reconnect, sync: new/edit/delete/conflict/folder-delete-vs-edit/3 MB/restart, sync over the link).
  It does not cover Bonjour discovery or the menu.

## Open
- Change detection is polling (3 s); fine for an exchange folder, not for very large trees (FSEvents).
- A scan reply is one frame (max 4 MB), roughly 20 000 entries.
- An edit made in the moment a copy over that same file is renamed into place can be lost.
- The dmg is ad-hoc signed: Gatekeeper needs right-click → Open the first time.
