# MusiRenderer

MusiRenderer is a native macOS UPnP/DLNA MediaRenderer. The current project is
the **Milestone 4** build with continuous HTTP playback, two-way seeking and
UPnP event notifications.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (the project is currently verified with Xcode 27.2)
- A Mac and controller device on the same IPv4 LAN

## Build and run

1. Open `MusiRenderer.xcodeproj`.
2. Select the `MusiRenderer` scheme and your Mac.
3. Build and run.
4. Approve local-network access if macOS asks.
5. Look for **MusiRenderer** in a UPnP control point such as MusiCards.

The menu-bar icon opens a small status and diagnostics panel. The renderer runs
without a player window.

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
- one prepared next URI via `SetNextAVTransportURI`, with automatic advancement at end of track
- `Next` consumes the prepared URI. `Previous` returns UPnP error 711 when a track is loaded because the control point owns playlist history.
- GENA subscriptions and renewal, with AVTransport and RenderingControl `LastChange` events
- volume and mute on the Master channel
- ALAC/M4A, MP3 and AAC protocol advertisement
- authenticated HTTP URLs, preserved without rebuilding their query strings

## Deliberate current limits

- Continuous playback requires the control point to supply each next URI. An empty next URI clears the queue, and playback stops at the end of the last track.
- The renderer preloads asset information for the next track. Sample-accurate gapless transitions remain a future improvement.
- GENA accepts HTTP callbacks to the same IPv4 address as the subscribing control point.
- Artwork and output-device selection are deferred.
- Discovery currently targets IPv4 home LANs, as required by SSDP interoperability.

## Diagnostics and privacy

Diagnostics record discovery and HTTP request metadata. URLs are sanitized;
credential-like query fields (`u`, `p`, `t`, `s`, `token`, `apiKey`, and similar)
are redacted. The initial renderer description never includes stream URLs.
