# ShareKeeper

One folder, `~/ShareKeeper`, with the same contents on all your Macs. Put a file in it on one Mac and it
appears on the other. Nothing else is shared, and there is nothing to set up after pairing.

- **No accounts, no cloud, no File Sharing.** Macs talk to each other directly over your local network.
- **Pair once.** Pick the other Mac in the menu, compare a six digit code on both screens, done.
- **Encrypted and authenticated.** Only Macs you paired can connect; everything is encrypted end to end.
- **Safe deletes.** A file deleted on one Mac goes to the Trash of the other, never straight away.
- **Conflicts keep both.** Changed on both Macs? Both versions stay, the other one as `name (Other Mac).ext`.
- Menu bar app with notifications; works again by itself after sleep or a network change.

## Install

1. Download `ShareKeeper-<version>.dmg` from the [releases](../../releases) and drag the app to Applications.
2. The app is not notarized, so the first time: right-click → **Open** (or
   `xattr -dr com.apple.quarantine /Applications/ShareKeeper.app`).
3. Do the same on your other Mac, allow access to the local network and notifications when asked.
4. On one Mac: menu bar icon → **Pair a New Mac** → choose the other Mac → confirm that both show the same code.

Requires macOS 13 or later.

## How it works

Macs find each other with Bonjour (`_sharekeeper._tcp`) and connect with a mutually authenticated key exchange
(X25519, HKDF) and ChaCha20-Poly1305 frames. Syncing is a three-way comparison against what both sides had
after the last run, which is what tells a new file from a deleted one. Details, decisions and known gaps are
in [AGENTS.md](AGENTS.md).

## Build

```bash
./build.sh && open ShareKeeper.app     # needs Xcode command line tools
./dmg.sh                               # ShareKeeper-<version>.dmg and .zip
Tests/run.sh                           # integration tests, no second Mac needed
```

`SIGN_IDENTITY=-` builds ad-hoc signed; otherwise the best code signing identity in your keychain is used.

## License

[MIT](LICENSE)
