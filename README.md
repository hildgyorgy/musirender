# MusiRenderer

MusiRenderer is a native macOS UPnP/DLNA MediaRenderer. The current project is
the **Milestone 1** discovery skeleton: it advertises a standards-shaped renderer
on the local network, responds to SSDP searches, and serves its UPnP description
documents over HTTP.

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

## Milestone 1 architecture

- `MusiRendererApp`: menu-bar lifecycle and diagnostics UI
- `RendererRuntime`: owns the service lifetime; no SwiftUI object owns a socket
- `SSDPService`: IPv4 multicast advertisements and M-SEARCH responses
- `UPnPDeviceServer`: small HTTP/1.1 server for device/service descriptions
- `UPnPDescriptions`: deterministic UPnP XML documents
- `DiagnosticLog`: bounded, redacted in-memory diagnostic stream

The HTTP and SSDP implementations use Apple system frameworks and Darwin
sockets only. There are no runtime dependencies.

## Deliberate Milestone 1 limits

- UPnP control and event URLs exist but return a standards-compatible UPnP
  `Invalid Action` response or an HTTP not-implemented response.
- Playback, AVTransport state, GENA subscriptions, artwork and RenderingControl
  behavior are deferred to later milestones.
- Discovery currently targets IPv4 home LANs, as required by SSDP interoperability.

## Diagnostics and privacy

Diagnostics record discovery and HTTP request metadata. URLs are sanitized;
credential-like query fields (`u`, `p`, `t`, `s`, `token`, `apiKey`, and similar)
are redacted. The initial renderer description never includes stream URLs.
