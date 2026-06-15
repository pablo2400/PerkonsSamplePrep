# PERKONS HD-01 Sample Prep

Small macOS app for preparing exactly three user samples for the Erica Synths PERKONS HD-01.

## Workflow

- Drop WAV files into the app or use `Add WAV...`.
- Files can be added one by one until the set has 3 samples.
- Select a file and click `Remove Selected` to replace it with another file.
- Select a file and press Space, or click `Preview`, to start/stop preview playback.
- The currently playing row shows a play triangle.
- While preview is playing, moving selection with arrow keys stops the previous file and starts the newly selected one.
- After conversion, the `Converted Output` list can be previewed the same way.
- Conversion is enabled only when exactly 3 files are loaded.

## Output

The app writes:

- `1.wav`
- `2.wav`
- `3.wav`

Each file is converted to:

- WAV
- mono
- 16-bit PCM
- 48 kHz

The combined output is kept under `256,000` bytes. If `Auto-trim to 256 KB total` is enabled, the app trims the three samples proportionally so the set fits the PERKONS limit.

## History

Every successful conversion is copied to:

```text
~/Library/Application Support/PerkonsSamplePrep/History
```

Each history set contains `1.wav`, `2.wav`, `3.wav`, and a `manifest.json` with source names, output sizes, durations, and timestamp.

## App

Run:

```text
/Users/pawel/PerkonsSamplePrep/PerkonsSamplePrep.app
```

## Background Image

The app uses this optional bundle resource as the window background:

```text
PerkonsSamplePrep.app/Contents/Resources/perkons-bg.png
```

`perkons-bg.jpg` also works. After adding or replacing the file, rebuild or re-sign the app bundle.

## History Names

History rows have an editable display name. Select a history row and use `Rename Selected...`.

## License

The source code is available under the
[PolyForm Noncommercial License 1.0.0](LICENSE).

You may use, modify, and share the software for noncommercial purposes.
Commercial use is not permitted under this license.

Because commercial use is restricted, this is a source-available license rather
than an OSI-approved open-source license.
