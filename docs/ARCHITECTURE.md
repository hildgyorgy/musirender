# Architecture and decisions

## Version 1 shape

The smallest robust design is one process with independent service objects:

```text
SwiftUI menu-bar UI
        │ observes diagnostics/state only
        ▼
RendererRuntime ── owns all long-lived services
   ├── SSDPService
   ├── UPnPDeviceServer
   │     ├── AVTransport handler       (Milestone 2+)
   │     ├── RenderingControl handler  (Milestone 2+)
   │     └── GENA subscriptions        (Milestone 4)
   └── PlaybackCoordinator             (Milestone 2+)
         └── AudioPlayer abstraction
```

`RendererRuntime`, not a view or window, owns network and future playback
lifetimes. UPnP action handlers should depend on a renderer-state protocol and a
playback protocol, so SOAP parsing and state-machine behavior can be tested
without audio hardware or sockets.

Milestone 1 implemented the runtime, HTTP server, SSDP service, deterministic XML
descriptions and bounded diagnostics. Milestone 2 adds a protocol-driven
`PlaybackCoordinator`, an AVPlayer adapter and a SOAP action handler without
coupling any of them to SwiftUI.

## Decisions

### Minimum deployment target: macOS 14 Sonoma

macOS 14 is the initial target. It preserves a useful hardware range while
providing a stable modern SwiftUI menu-bar baseline. Lowering the target would
increase compatibility work before discovery and playback behavior are proven.
The core currently uses older system APIs and can be reassessed after the first
real-device tests.

### Swift Package plus Xcode application

Networking and UPnP code lives in `MusiRendererCore`, built and tested by Swift
Package Manager. The Xcode application compiles the same sources into a native
menu-bar `.app`. This avoids a third-party project generator and keeps protocol
logic independently testable.

### Darwin UDP sockets for SSDP

SSDP needs control over IPv4 multicast membership, outbound interface selection,
source addresses and unicast replies. Darwin sockets make these requirements
explicit and avoid depending on higher-level multicast behavior that differs
between OS releases. Network.framework is used for the TCP HTTP server.

### Fixed HTTP port

Milestone 1 uses TCP port `49494`. A fixed port makes advertisements stable and
diagnostics straightforward. A later settings layer may make it configurable,
but every SSDP `LOCATION` is always derived from the actual configured port.

### Stable identity

The app creates one UUID and stores it in `UserDefaults`. Restarting the app does
not change the UDN. Deleting the app's preferences intentionally creates a new
logical renderer.

### App Sandbox

The initial Developer ID-style build has App Sandbox disabled and Hardened
Runtime enabled. Multicast receiving and local HTTP serving must first be proven
across target macOS releases. Sandboxing is not required for outside-the-Mac-App-
Store distribution and can be evaluated later without coupling it to discovery
debugging.

## Main technical risks

### SSDP and network interfaces — high

Multicast can be affected by Wi-Fi isolation, VPNs, multiple active interfaces,
firewalls and macOS local-network authorization. The implementation joins every
active, non-loopback IPv4 multicast interface and chooses the response interface
whose subnet contains the requester. SSDP checks for changed IPv4 interfaces
every five seconds and refreshes multicast membership after system wake.

Real-device validation must cover Wi-Fi, Ethernet, VPN enabled/disabled, network
switching and sleep/wake. Packet capture is more useful than optimistic UI state.

### HTTP/SOAP correctness — medium

UPnP controllers vary in header casing, quoting, XML namespaces and tolerance of
HTTP behavior. The current HTTP parser is deliberately small and bounded. SOAP
actions are placeholders returning UPnP error 401 until their milestone is
implemented. Each future action needs fixture tests from MusiCards plus a second
independent control point.

### GENA eventing — high

GENA requires subscription renewal, expiration, callback URL validation,
sequence numbers, LastChange XML escaping and failure cleanup. It should be a
dedicated subscription manager driven by committed renderer-state changes, not
mixed into SOAP action handlers. Milestone 4 uses a dedicated subscription
manager with per-subscriber sequence numbers, timeouts and same-peer callbacks.

### AVPlayer and authenticated ALAC — high

AVPlayer usually supports ALAC in an M4A container over HTTP, but behavior depends
on server responses, redirects, MIME type, byte-range support and URL lifetime.
Navidrome URLs may contain authentication query parameters and no extension.
Milestone 2 must test the real server before choosing the final player API.

The first playback spike should verify:

- the exact Navidrome response and redirect chain;
- ALAC/M4A playback without relying on a filename extension;
- seekability and duration with HTTP range requests;
- cancellation and replacement of an in-flight item;
- whether headers or URL credentials are required;
- redaction of authentication fields in all errors and logs.

`AudioPlayer` must remain an abstraction. If AVPlayer cannot deliver reliable
transitions or later output-device control, AVPlayerItem/AVAsset or an
AVAudioEngine-based implementation can replace it without changing UPnP code.

### Continuous playback — high

`SetNextAVTransportURI` is renderer state, not a playlist. The future coordinator
must atomically promote the prepared next item and its metadata when playback
actually advances. State and GENA notifications must reflect committed player
events, never merely accepted commands.

### Credentials in diagnostics — high impact

The diagnostic log redacts common Navidrome/OpenSubsonic query fields before
storage or UI display. Future logging must route through the same redaction
boundary; raw AVFoundation errors and full URLs must not be sent directly to OSLog.

## Milestone 1 interoperability contract

- IPv4 SSDP multicast group `239.255.255.250:1900`
- UPnP 1.1-style `BOOTID.UPNP.ORG` and `CONFIGID.UPNP.ORG`
- advertisements for root device, UUID, MediaRenderer and all three services
- M-SEARCH matching for specific targets and `ssdp:all`
- per-interface `LOCATION` URL
- device, AVTransport, RenderingControl and ConnectionManager SCPDs over HTTP
- control and event URLs are present; functionality is explicitly deferred
- graceful `ssdp:byebye` on normal app termination
