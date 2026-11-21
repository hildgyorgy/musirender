# MusiRender 0.2.0

Requires an Apple silicon Mac running macOS 26 Tahoe or later. To install,
drag MusiRender.app into Applications.

## What’s new

- Select a dedicated audio device while keeping the macOS default output.
- Enable fixed digital volume, automatic source sample-rate matching and
  optional exclusive access for the selected device.
- See the source server and track format separately from the active device
  and its nominal sample rate. MusiCards streams from Navidrome now show the
  source name.
- The menu-bar speaker turns blue when the renderer is online. Its tooltip
  shows the current status.

## What we verified

- All 28 automated tests passed for this release. The Release build is
  arm64 and declares macOS 26.0 as its minimum.
- UPnP playback with MusiCards and with mconnect Player paired with Gerbera.
  The Tosca ALAC listening test confirmed seamless playback on the tested
  album. With automatic rate matching enabled, a change of sample rate can
  cause a brief pause between tracks.
- A physical MOJO 2 on USB played at 44.1 and 96 kHz in exclusive mode. The
  Stop command released ownership of the device.
- The exact PCM sample values of the 44.1 kHz / 16-bit and 96 kHz / 24-bit
  ALAC references matched at a track-level tap inside AVQueuePlayer.
  The comparison detected a deliberately altered bit. Measurement of the
  samples arriving at the physical DAC input remains open.

## Next steps

- Test startup without a LAN and recovery after a network interruption,
  router restart and sleep. A listener failure can currently leave the
  renderer offline until the app restarts.
- Test HTTP playback and controller negotiation for FLAC, WAV and AIFF
  before advertising additional formats. Extend testing of track changes,
  including a missing or unplayable next item.

## Longer-term plans

- Verify complete digital paths at the DAC input and publish results by
  device, interface and PCM format.
- Improve unattended operation on a dedicated Mac and measure gapless
  transitions from digital captures.

For the test files and comparison workflow, see the project’s
`docs/BIT_PERFECT.md`.
