# ShareKeeper

Menu bar app for my own Macs: share one folder, and mount the folders of my other Macs as volumes.
Personal use, macOS only. A Mac with restrictions may have File Sharing off, so this does not use it.

## How it works
- **Own link between Macs** (`Sources/Core`): Bonjour `_sharekeeper._tcp`, then a TCP connection that is
  mutually authenticated and encrypted by our own handshake (`Crypto.swift`): X25519 static + ephemeral
  keys, HKDF, ChaCha20-Poly1305 frames. Request/response RPC with a JSON header and raw file bytes (`Wire.swift`).
- **Pairing** is once per pair of Macs: numeric comparison of a six digit code on both screens, with a
  commit/reveal so a man in the middle cannot grind keys that give the same code. One Mac picks the other
  from the Bonjour list ("Pair with…"); the other shows the code prompt by itself (no "allow pairing" mode,
  the user has to confirm the code anyway; one prompt at a time). After pairing each side stores the other's
  public key; a Mac that never shared anything starts sharing `~/ShareKeeper Drop` (created, announced in an alert, changeable in the menu — not re-enabled for someone who turned sharing off or chose a folder); unknown or wrong-key peers are dropped before any file
  data is exchanged.
- **Not sharing is a state, not an error**: a paired Mac with sharing off still connects; `ping` answers
  `sharing: false`, files answer EACCES, the menu says "not sharing a folder yet", and the mounting Mac
  mounts by itself within ~10 s (the ping interval) of the other turning sharing on.
- **Sharing side** (`FileServer.swift`): serves one chosen folder. All confinement is here, on the Mac that
  owns the files: no `..`, symlinks only followed when they stay inside the folder (others are hidden).
  Sharing off / read-only is checked per request, so it applies to links that are already open.
- **Mounting side** (`NFS.swift`): a small NFSv3 + MOUNT server on 127.0.0.1 (same idea as Continuo) that
  turns NFS calls into RPCs on the link; `mount_nfs` mounts it at `~/ShareKeeper/<Mac name>`.
  Only calls from our own uid (or root) are accepted, because any local process can reach a loopback port.
  The mount survives a lost link: requests wait up to 6 s for the reconnect, then fail with EIO.
  Mount options matter: `soft,dumbtimer,timeo=100`. Without `dumbtimer` the client learns the loopback
  round trip time and gives up on a soft mount after well under a second (ETIMEDOUT), so a reconnect
  after sleep would surface as errors.
- `App/main.swift` is only the menu bar UI and glue (wake / network change → reconnect, stale mount cleanup
  at launch, unmount at quit).

## Decisions
- Rejected: macOS File Sharing/SMB ((not available) blocks it on one Mac; v0.1 of this repo did that), FUSE
  (driver install, three platforms), WebDAV (macOS fetches whole files; writes need fake locks),
  FileDonkey's code (CC BY-NC, and no auth, no path confinement). We read its design, copied nothing.
- Loopback NFS over WebDAV for partial reads and normal write semantics.
- The private key is a 0600 file in `~/Library/Application Support/ShareKeeper`, not the keychain: an
  ad-hoc signed rebuild would make the keychain prompt again.
- Not supported on purpose: symlinks, hard links, device nodes, extended attributes, file locking across
  Macs (`locallocks`: locks are local only).

## Build / test
- `./build.sh && open ShareKeeper.app`. Logs: `log stream --predicate 'subsystem == "nl.david.ShareKeeper"'`.
- `Tests/run.sh`: both sides in one process over loopback, mounted through the real NFS client (about
  50 checks: confinement, pairing, strangers refused, file ops via `cp/mv/rm`, reconnect, sharing off).
  It does not cover Bonjour discovery or the menu.

## Open
- Not yet tried between two real Macs (Bonjour discovery, the Local Network permission prompt, sleep/wake).
- Finder sidebar: a mount at `~/ShareKeeper/…` is not in the sidebar; use "Open in Finder" or drag the folder in.
- No rate limiting on pairing attempts; pairing is only open for two minutes after the user asks for it.
