# Jitter Measurement — iOS Client Implementation Guide

> **Feature**: Client-side audio chunk IPDV jitter measurement
> **Target**: iOS snapcast client developers
> **Reference implementation**: `client/controller.cpp` (C++)
> **Protocol version**: SnapStreamProtocolVersion 2

---

## Background

Snapcast streams audio as a sequence of compressed frames called **WireChunks** (~50 per second, one per 20 ms of audio). The server stamps each chunk with the time it was sent (`sent` field in the base message header). The client records the time it received each chunk (`received` field).

**Inter-Packet Delay Variation (IPDV)** measures how consistently those chunks arrive. On a perfect network, the gap between consecutive received chunks equals the gap between their sent timestamps. Any deviation is IPDV — the standard metric for perceptible audio glitching.

```
IPDV[n] = |(recv[n] - recv[n-1]) - (sent[n] - sent[n-1])|
```

Clock offsets between server and client cancel out in the subtraction (RFC 3550 §6.4.1), so no time synchronization is required for this calculation.

The client accumulates IPDV samples in a ring buffer and periodically reports statistics to the server via a `ClientInfo` message. The server exposes them through the `Client.GetTimeStats` JSON-RPC method, used by management UIs, monitoring tools, or adaptive buffer algorithms.

---

## Protocol Reference

All multi-byte integers are **little-endian**. The protocol uses a 26-byte binary base header followed by a typed payload.

### Base Message Header (26 bytes)

```
Offset  Size  Type    Field            Description
------  ----  ------  ---------------  -----------
0       2     uint16  type             Message type (see table below)
2       2     uint16  id               Message ID (for request/response correlation)
4       2     uint16  refersTo         ID of the request this responds to
6       4     int32   sent.sec         Seconds — set by SENDER before transmit
10      4     int32   sent.usec        Microseconds — set by SENDER before transmit
14      4     int32   received.sec     Seconds — set by RECEIVER on arrival
18      4     int32   received.usec    Microseconds — set by RECEIVER on arrival
22      4     uint32  size             Byte length of the typed payload that follows
```

### Message Types

| Value | Name           | Direction | Notes                               |
|-------|----------------|-----------|-------------------------------------|
| 0     | Base           | —         | Never sent standalone               |
| 1     | CodecHeader    | S→C       | Stream start; initialize decoder    |
| 2     | WireChunk      | S→C       | Audio frame, ~50/s                  |
| 3     | ServerSettings | S→C       | Volume, mute, buffer config         |
| 4     | Time           | C↔S       | Time-sync ping/pong, ~1/s           |
| 5     | Hello          | C→S       | Client identification on connect    |
| 7     | ClientInfo     | C→S       | Volume/mute + optional jitter stats |
| 8     | Error          | S→C       | Auth or protocol error              |

### WireChunk Typed Payload

```
Offset  Size  Type    Field              Description
------  ----  ------  ---------------    -----------
0       4     int32   timestamp.sec      Playout time (server clock), seconds
4       4     int32   timestamp.usec     Playout time (server clock), microseconds
8       4     uint32  payloadSize        Byte count of encoded audio data
12      var   bytes   payload            Encoded audio (FLAC / Ogg / Opus / PCM)
```

> **Important**: `timestamp` is the *playout* time on the server clock, **not** the send time.
> For IPDV, use `base.sent` (server transmit time) and `base.received` (client arrival time),
> not `timestamp`.

### ClientInfo Typed Payload (JSON)

```
Offset  Size    Type    Field    Description
------  ------  ------  ------   -----------
0       4       uint32  size     Byte length of the JSON string (little-endian)
4       size    bytes   json     UTF-8 JSON, no null terminator
```

**Minimal JSON** (always required):
```json
{"volume": 85, "muted": false}
```

**With jitter stats** (optional — include only when >= 50 samples have been collected):
```json
{
  "volume": 85,
  "muted": false,
  "jitter_median_us": 1240,
  "jitter_p95_us": 4100,
  "jitter_samples": 127
}
```

| Field              | Type   | Unit         | Notes                              |
|--------------------|--------|--------------|------------------------------------|
| `volume`           | uint16 | percent 0–100| Required                           |
| `muted`            | bool   |              | Required                           |
| `jitter_median_us` | int64  | microseconds | Optional; omit if < 50 samples     |
| `jitter_p95_us`    | int64  | microseconds | Optional; omit if < 50 samples     |
| `jitter_samples`   | uint32 | count        | Optional; number of samples in buf |

**Backward compatibility**: servers older than this feature ignore unknown JSON keys.
The `jitter_*` fields are purely additive — never required, never break old servers.

---

## Connection Sequence

```
Client                              Server
  |                                   |
  |─── Hello ────────────────────────▶|
  |◀── ServerSettings ────────────────|  record volume/mute; serverSettingsReceived = true
  |◀── CodecHeader ───────────────────|  init decoder; call resetJitterState()
  |◀── WireChunk ─────────────────────|  stamp received; call onWireChunk()
  |◀── WireChunk ─────────────────────|
  |  ... (continuous stream) ...      |
  |─── Time ─────────────────────────▶|  time-sync request (~every 1s)
  |◀── Time ──────────────────────────|  call onTimeSyncComplete() here
  |─── ClientInfo (+ jitter) ────────▶|  every 5th sync, if >= 50 samples
  |◀── WireChunk ─────────────────────|
  |  ...                              |
```

---

## Implementation

### State

Add these fields to your connection/stream controller class:

```swift
// MARK: - Jitter Measurement State

/// Protects jitterBuffer: written on receive queue, read on time-sync callback
private let jitterLock = NSLock()

/// Ring buffer of |IPDV| samples in microseconds; capacity 200 (~4s at 50Hz)
private var jitterBuffer: [Int64] = []
private let jitterBufferCapacity = 200

/// Previous chunk timestamps — only touched from the receive queue (no lock needed)
private var prevChunkRecvUsec: Int64 = 0
private var prevChunkSentUsec: Int64 = 0
private var hasPrevChunkTimestamps = false

/// Counts time-sync cycles; report every kJitterReportInterval cycles
private var jitterReportCounter: Int = 0
private let kJitterReportInterval = 5

/// Set to true once the first ServerSettings message is received.
/// Guards against sending ClientInfo with the default volume {100, false}
/// before the server has told us the real value — a jitter report carrying
/// wrong volume would silently overwrite the server's authoritative record.
private var serverSettingsReceived = false

/// Last known volume (0–100) and mute state — updated from ServerSettings
private var currentVolumePct: Int = 100
private var currentMuted: Bool = false
```

### Step 1 — Record `received` timestamp

Stamp `received` **as soon as the 26-byte header is fully read** from the socket, before reading the audio payload.

```swift
func readBaseHeader(from stream: InputStream) throws -> BaseHeader {
    var rawHeader = [UInt8](repeating: 0, count: 26)
    let n = stream.read(&rawHeader, maxLength: 26)
    guard n == 26 else { throw SnapError.connectionClosed }

    // Stamp arrival time immediately — monotonic clock, microseconds
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    let receivedUsecTotal = Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1000

    var header = BaseHeader()
    header.type         = readLE16(rawHeader, offset: 0)
    header.id           = readLE16(rawHeader, offset: 2)
    header.refersTo     = readLE16(rawHeader, offset: 4)
    header.sentSec      = readLE32(rawHeader, offset: 6)
    header.sentUsec     = readLE32(rawHeader, offset: 10)
    // received.sec / received.usec at offsets 14–21 come from the wire
    // but for outgoing messages you fill them in yourself (see below)
    header.receivedSec  = Int32(receivedUsecTotal / 1_000_000)
    header.receivedUsec = Int32(receivedUsecTotal % 1_000_000)
    header.payloadSize  = readLE32(rawHeader, offset: 22)
    return header
}
```

Little-endian helpers (if not already in your codebase):
```swift
func readLE16(_ b: [UInt8], offset: Int) -> Int {
    Int(b[offset]) | (Int(b[offset+1]) << 8)
}
func readLE32(_ b: [UInt8], offset: Int) -> Int32 {
    Int32(bitPattern:
        UInt32(b[offset])       |
        UInt32(b[offset+1]) << 8  |
        UInt32(b[offset+2]) << 16 |
        UInt32(b[offset+3]) << 24)
}
```

### Step 2 — Compute IPDV on each WireChunk

Call this from your receive queue for every message of type `2` (WireChunk):

```swift
/// Called from the network receive queue for every WireChunk.
/// sentSec / sentUsec come from base.sent in the message header.
/// recvSec / recvUsec come from base.received stamped in Step 1.
func onWireChunk(sentSec: Int32, sentUsec: Int32,
                 recvSec: Int32, recvUsec: Int32) {
    let recvUs = Int64(recvSec) * 1_000_000 + Int64(recvUsec)
    let sentUs = Int64(sentSec) * 1_000_000 + Int64(sentUsec)

    if hasPrevChunkTimestamps {
        let ipdv = abs((recvUs - prevChunkRecvUsec) - (sentUs - prevChunkSentUsec))

        // jitterBuffer is also read from the time-sync callback — lock required
        jitterLock.lock()
        jitterBuffer.append(ipdv)
        if jitterBuffer.count > jitterBufferCapacity {
            jitterBuffer.removeFirst()
        }
        jitterLock.unlock()
    }

    // These fields are only touched from the receive queue — no lock needed
    prevChunkRecvUsec      = recvUs
    prevChunkSentUsec      = sentUs
    hasPrevChunkTimestamps = true
}
```

### Step 3 — Report jitter after each time-sync response

Call this from your time-sync response handler, after processing the `Time` message (type `4`):

```swift
/// Called after each Time response is received (~1 Hz).
/// Sends a ClientInfo with jitter stats every kJitterReportInterval cycles.
func onTimeSyncComplete() {
    jitterReportCounter += 1
    guard jitterReportCounter >= kJitterReportInterval else { return }
    jitterReportCounter = 0   // always reset, even if we skip sending

    guard serverSettingsReceived else { return }   // real volume must be known

    jitterLock.lock()
    let hasEnough = jitterBuffer.count >= 50
    let snapshot  = hasEnough ? jitterBuffer : nil
    jitterLock.unlock()

    guard let samples = snapshot else { return }

    let sorted = samples.sorted()
    let median = percentile(sorted, p: 50)
    let p95    = percentile(sorted, p: 95)

    sendClientInfo(
        volumePct:      currentVolumePct,
        muted:          currentMuted,
        jitterMedianUs: median,
        jitterP95Us:    p95,
        jitterSamples:  UInt32(samples.count)
    )
}

/// Percentile index formula — must match the server's DoubleBuffer::percentile().
/// index = floor((count - 1) * p / 100.0)
private func percentile(_ sorted: [Int64], p: Int) -> Int64 {
    let idx = Int(Double(sorted.count - 1) * Double(p) / 100.0)
    return sorted[idx]
}
```

### Step 4 — Build and send ClientInfo

```swift
/// Sends a ClientInfo message (type 7).
/// jitter parameters are optional — pass nil to send a plain volume/mute update.
func sendClientInfo(volumePct: Int,
                    muted: Bool,
                    jitterMedianUs: Int64? = nil,
                    jitterP95Us: Int64? = nil,
                    jitterSamples: UInt32? = nil) {
    // Build JSON dictionary
    var dict: [String: Any] = [
        "volume": volumePct,
        "muted":  muted
    ]
    if let median = jitterMedianUs,
       let p95    = jitterP95Us,
       let count  = jitterSamples {
        dict["jitter_median_us"] = median
        dict["jitter_p95_us"]    = p95
        dict["jitter_samples"]   = count
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
    let jsonLen = UInt32(jsonData.count)

    // Typed payload = 4-byte LE string-length prefix + JSON bytes
    let payloadLen = Int(4 + jsonLen)

    // 26-byte base header
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    let nowSec  = Int32(ts.tv_sec)
    let nowUsec = Int32(ts.tv_nsec / 1000)

    var packet = Data(capacity: 26 + payloadLen)
    packet.appendLE16(7)                // type = kClientInfo
    packet.appendLE16(UInt16(nextMessageId()))
    packet.appendLE16(0)               // refersTo
    packet.appendLE32(nowSec)          // sent.sec
    packet.appendLE32(nowUsec)         // sent.usec
    packet.appendLE32(0)               // received.sec (unused for outgoing)
    packet.appendLE32(0)               // received.usec
    packet.appendLE32(UInt32(payloadLen)) // size

    // Typed payload
    packet.appendLE32(jsonLen)         // JSON string length prefix
    packet.append(jsonData)

    send(packet)
}
```

Little-endian `Data` helpers:
```swift
extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
    mutating func appendLE32(_ v: Int32) { appendLE32(UInt32(bitPattern: v)) }
}
```

### Step 5 — Handle ServerSettings

```swift
func onServerSettings(payload: Data) {
    // Typed payload: 4-byte LE length prefix + UTF-8 JSON
    let jsonLen = Int(readLE32(Array(payload), offset: 0))
    guard payload.count >= 4 + jsonLen else { return }
    let jsonData = payload.subdata(in: 4 ..< 4 + jsonLen)

    guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    else { return }

    currentVolumePct       = obj["volume"] as? Int  ?? 100
    currentMuted           = obj["muted"]  as? Bool ?? false
    serverSettingsReceived = true

    // Apply bufferMs / latency to your audio buffer as usual...
}
```

### Step 6 — Reset on reconnect and codec change

```swift
/// Call when the TCP connection drops, before reconnecting.
func resetOnDisconnect() {
    hasPrevChunkTimestamps = false
    jitterReportCounter    = 0
    serverSettingsReceived = false
    jitterLock.lock()
    jitterBuffer.removeAll(keepingCapacity: true)
    jitterLock.unlock()
}

/// Call when a CodecHeader message (type 1) is received — a new stream is starting.
/// Do NOT reset serverSettingsReceived here; the server will NOT resend
/// ServerSettings within the same connection.
func resetOnCodecHeader() {
    hasPrevChunkTimestamps = false
    jitterReportCounter    = 0
    jitterLock.lock()
    jitterBuffer.removeAll(keepingCapacity: true)
    jitterLock.unlock()
}
```

---

## Thread Safety Notes

| Field | Written from | Read from | Lock required |
|-------|--------------|-----------|---------------|
| `jitterBuffer` | receive queue | time-sync callback | **yes** — `jitterLock` |
| `prevChunkRecvUsec` | receive queue | receive queue only | no |
| `prevChunkSentUsec` | receive queue | receive queue only | no |
| `hasPrevChunkTimestamps` | receive queue | receive queue only | no |
| `jitterReportCounter` | time-sync callback | time-sync callback only | no |
| `serverSettingsReceived` | parse queue | time-sync callback | use serial queue or `os_unfair_lock` |
| `currentVolumePct` / `currentMuted` | parse queue | time-sync callback | same as above |

If all message processing (WireChunk, Time, ServerSettings) runs on a single serial `DispatchQueue`, no additional locking is needed beyond `jitterLock` for the buffer. This is the simplest architecture and the one to prefer.

---

## Acceptance Criteria

1. After ~10 seconds of playback, calling `Client.GetTimeStats` via the server's JSON-RPC API returns non-zero `audio_jitter_median_ms` and `audio_jitter_p95_ms` for the iOS client's entry.
2. `audio_samples` is between 50 and 200 (bounded by ring buffer capacity).
3. After disconnect + reconnect, `audio_samples` returns to 0 and builds back up cleanly.
4. Changing volume on the server does **not** trigger an extra jitter report — only the 5-cycle cadence fires `sendClientInfo`.
5. Connecting to a server running an older version (pre-PR #5) produces no error — the server silently ignores the extra JSON fields.
6. Clean bill of health under Xcode Thread Sanitizer (TSan) with no data races reported.

---

## Verification

To verify your implementation without a full Snapcast server, call `Client.GetTimeStats` via the control socket (default TCP port 1705, newline-delimited JSON-RPC):

```json
{"id": 1, "jsonrpc": "2.0", "method": "Client.GetTimeStats", "params": {"id": "<your-client-id>"}}
```

Expected response (after ~10s of playback):
```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "id": "<client-id>",
    "control_jitter_median_ms": 0.12,
    "control_jitter_p95_ms": 0.45,
    "control_samples": 42,
    "audio_jitter_median_ms": 1.8,
    "audio_jitter_p95_ms": 5.2,
    "audio_samples": 127,
    "suggested_buffer_ms": -8
  }
}
```

`audio_jitter_*` and `audio_samples` being non-zero confirms the iOS client is reporting correctly.

The `suggested_buffer_ms` value is informational — negative means estimated jitter exceeds the safety threshold and the buffer could benefit from being increased. No automatic action is taken by the server.
