# MusiRender

MusiRender is a native macOS UPnP/DLNA MediaRenderer. The current project is
the **Milestone 5** build with a compact player, continuous HTTP playback,
UPnP events and a controller-readable stream format report.

## Requirements

- An Apple silicon Mac running macOS 26 Tahoe or later
- Xcode 26 or later (the project is currently verified with Xcode 27.2)
- A Mac and controller device on the same IPv4 LAN

## Build and run

1. Open `MusiRenderer.xcodeproj`.
2. Select the `MusiRenderer` scheme and your Mac.
3. Build and run.
4. Approve local-network access if macOS asks.
5. Look for **MusiRender** in a UPnP control point such as MusiCards.

The menu-bar icon opens the player controls, artwork supplied by the controller,
stream format, diagnostics and the Launch at Login setting. The window button
opens a separate compact player. The renderer can run with both views closed.
macOS Now Playing shows the active track and provides system media controls.
To use Launch at Login outside development, keep the app at a stable path.

Under **Settings**, choose **System Default** or a specific audio output while
playback is stopped. The **Output** line includes the device’s nominal sample
rate when Core Audio reports it. For a selected device, **Fixed digital volume
(100%)** leaves listening volume to the DAC or amplifier and locks the
renderer’s volume and mute controls, including UPnP commands. If the selected
device disconnects, the renderer returns to System Default and restores
variable volume. An explicit Play resumes playback on the system output.
**Match source sample rate** is optional for a selected device. The renderer
waits for Core Audio to confirm the new rate before playing. Tracks whose
sample rates match can still be queued for gapless playback. Tracks that
require a rate change can have a brief pause between them.
**Exclusive audio output** reserves the selected device during playback.
Pause, Stop and the end of the queue release it. If macOS cannot grant access,
the renderer reports the error and waits for another Play request.

Core tests can also be run from Terminal:

```sh
swift test
```

## Architecture

- `MusiRendererApp`: menu-bar lifecycle and diagnostics UI
- `RendererRuntime`: owns the service lifetime; no SwiftUI object owns a socket
- `SSDPService`: IPv4 multicast advertisements and M-SEARCH responses
- `UPnPDeviceServer`: small HTTP/1.1 server for device/service descriptions
- `UPnPDescriptions`: deterministic UPnP XML documents
- `SOAPActionHandler`: AVTransport, RenderingControl and ConnectionManager actions
- `EventSubscriptionManager`: GENA subscription lifecycle and state notifications
- `PlaybackCoordinator`: transport state machine independent of SwiftUI
- `AVPlayerAudioPlayer`: Apple-native HTTP audio playback adapter
- `DiagnosticLog`: bounded, redacted in-memory diagnostic stream

The HTTP and SSDP implementations use Apple system frameworks and Darwin
sockets only. There are no runtime dependencies.

## Current playback support

- `SetAVTransportURI`, Play, Pause and Stop
- transport, media and position polling
- time-based seeking from a UPnP controller or the menu-bar position slider
- autonomous album playback from a downloaded DIDL-S playlist, or one prepared next URI via `SetNextAVTransportURI`
- `Next` advances within the downloaded album or consumes the prepared URI. `Previous` currently returns UPnP error 711 when a track is loaded.
- GENA subscriptions and renewal, with AVTransport and RenderingControl `LastChange` events
- volume and mute on the Master channel
- ALAC/M4A, MP3 and AAC protocol advertisement
- authenticated HTTP URLs, preserved without rebuilding their query strings
- SSDP rejoins IPv4 multicast after an interface change and reannounces on wake
- the renderer advertises only after its HTTP listener starts successfully

## Stream format API

A control point can use the origin of the device description's SSDP
`LOCATION` and request `GET /api/v1/audio-format`. This is a MusiRender HTTP
extension. Standard UPnP actions and events are unchanged.

```json
{
  "itemID": "D79B4519-DA79-4CAB-862D-C187E4FC8F3F",
  "transportState": "PLAYING",
  "transportStatus": "OK",
  "stream": {
    "codec": "ALAC",
    "sampleRateHz": 96000,
    "bitDepth": 24,
    "channels": 2,
    "estimatedBitrateBps": 2400000
  }
}
```

The `stream` object describes the audio track opened by AVPlayer. The bitrate is
the track's estimated encoded rate in bits per second. It is not download
throughput or a measurement of the Core Audio/DAC output. Fields are omitted
until available, including bit depth for lossy codecs. `itemID` changes when a
track is loaded, including a retry. The report contains no media URLs or tokens.
A controller can poll it after a track change and retry if `stream` is absent.

## Bit-perfect playback testing

The [PCM measurement workflow](docs/BIT_PERFECT.md) includes test signals and
a sample-by-sample comparison for digital captures.

## Releases

GitHub Actions builds and publishes the notarized DMG from a version tag.
See [Publishing a version](docs/RELEASING.md) for the one-time setup.

## Deliberate current limits

- SOAP requests use `Content-Length`. The server supports `Expect: 100-continue`
  and rejects chunked requests with HTTP 501.

- A controller that hands off a DIDL-S album can disconnect after the renderer confirms receipt. Other controllers can supply each next URI individually. Playback stops at the end of the last track.
- DIDL-S playlists use sequential mode and track-relative seeking. The handoff accepts an HTTP playlist URL at the address of the requesting IPv4 controller.
- The renderer queues the next audio item in AVQueuePlayer before the current
  track ends. Seamlessness depends on the stream, audio format and buffering.
- GENA accepts HTTP callbacks to the same IPv4 address as the subscribing control point.
- Bit-perfect playback has yet to be verified at the physical output.
- If an audio stream fails permanently, Play retries from the start of the
  current track and retains the queued next URI.
- Discovery currently targets IPv4 home LANs, as required by SSDP interoperability.

## Diagnostics and privacy

Diagnostics record discovery and HTTP request metadata. URLs are sanitized;
credential-like query fields (`u`, `p`, `t`, `s`, `token`, `apiKey`, and similar)
are redacted. The initial renderer description never includes stream URLs.
