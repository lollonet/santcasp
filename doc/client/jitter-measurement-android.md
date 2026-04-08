# Jitter Measurement — Android Client Implementation Guide

> **Feature**: Client-side audio chunk IPDV jitter measurement
> **Target**: Android snapcast client developers
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

The client accumulates IPDV samples in a ring buffer and periodically reports statistics to the server via a `ClientInfo` message. The server exposes them through the `Client.GetTimeStats` JSON-RPC method, which can be used by management UIs, monitoring tools, or adaptive buffer algorithms.

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

Parse with a `ByteBuffer` in little-endian order:
```kotlin
val buf = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
val type       = buf.getShort(0).toInt() and 0xFFFF
val id         = buf.getShort(2).toInt() and 0xFFFF
val refersTo   = buf.getShort(4).toInt() and 0xFFFF
val sentSec    = buf.getInt(6)
val sentUsec   = buf.getInt(10)
// received.sec / received.usec: YOU fill these in (see Step 1)
val payloadLen = buf.getInt(22).toLong() and 0xFFFFFFFFL
```

### Message Types

| Value | Name           | Direction | Notes                              |
|-------|----------------|-----------|------------------------------------|
| 0     | Base           | —         | Never sent standalone              |
| 1     | CodecHeader    | S→C       | Stream start; initialize decoder   |
| 2     | WireChunk      | S→C       | Audio frame, ~50/s                 |
| 3     | ServerSettings | S→C       | Volume, mute, buffer config        |
| 4     | Time           | C↔S       | Time-sync ping/pong, ~1/s          |
| 5     | Hello          | C→S       | Client identification on connect   |
| 7     | ClientInfo     | C→S       | Volume/mute + optional jitter stats|
| 8     | Error          | S→C       | Auth or protocol error             |

### WireChunk Typed Payload

```
Offset  Size  Type    Field              Description
------  ----  ------  ---------------    -----------
0       4     int32   timestamp.sec      Playout time (server clock), seconds
4       4     int32   timestamp.usec     Playout time (server clock), microseconds
8       4     uint32  payloadSize        Byte count of encoded audio data
12      var   bytes   payload            Encoded audio (FLAC / Ogg / Opus / PCM)
```

> **Important**: For IPDV, use `timestamp` (audio playout time) as the sent reference and
> `base.received` (client arrival time) as the received reference. Do **not** use `base.sent` —
> it is set once at serialization time and is identical for all clients, measuring server encoding
> stability rather than network delivery jitter. The `timestamp` field advances by exactly
> `chunk_ms` per chunk, providing a perfectly regular reference.

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

**With jitter stats** (optional, include when ≥50 samples collected):
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
| `volume`           | int    | percent 0–100| Required                           |
| `muted`            | bool   |              | Required                           |
| `jitter_median_us` | long   | microseconds | Optional; omit if < 50 samples     |
| `jitter_p95_us`    | long   | microseconds | Optional; omit if < 50 samples     |
| `jitter_samples`   | int    | count        | Optional; number of samples in buf |

**Backward compatibility**: servers older than this feature ignore unknown JSON keys. The `jitter_*` fields are purely optional — never required.

---

## Connection Sequence

```
Client                              Server
  |                                   |
  |─── Hello ────────────────────────▶|
  |◀── ServerSettings ────────────────|  ← store volume/mute; set serverSettingsReceived = true
  |◀── CodecHeader ───────────────────|  ← init decoder; call resetJitterState()
  |◀── WireChunk ─────────────────────|  ← stamp received; call onWireChunk()
  |◀── WireChunk ─────────────────────|
  |  ... (continuous stream) ...      |
  |─── Time ─────────────────────────▶|  ← time-sync request (~every 1s)
  |◀── Time ──────────────────────────|  ← call onTimeSyncComplete() here
  |─── ClientInfo (+ jitter) ────────▶|  ← every 5th sync, if ≥50 samples
  |◀── WireChunk ─────────────────────|
  |  ...                              |
```

---

## Implementation

### State

Add the following fields to your connection or stream controller class:

```kotlin
// ── Jitter measurement ────────────────────────────────────────────────────

/** Guards jitterBuffer: written from IO thread, read from time-sync thread */
private val jitterLock = Any()

/** Ring buffer of |IPDV| values in microseconds. Capacity 200 ≈ 4s at 50Hz. */
private val jitterBuffer = ArrayDeque<Long>(200)
private val JITTER_BUFFER_CAPACITY = 200

/** Previous chunk timestamps — only touched from the IO/receive thread */
@Volatile private var prevChunkRecvUsec: Long = 0
@Volatile private var prevChunkSentUsec: Long = 0
@Volatile private var hasPrevChunkTimestamps: Boolean = false

/** Counts time-sync cycles; report jitter every JITTER_REPORT_INTERVAL cycles */
private var jitterReportCounter: Int = 0
private val JITTER_REPORT_INTERVAL = 5

/**
 * Set to true once the first ServerSettings message arrives.
 * Prevents sending ClientInfo with the default volume (100, unmuted) before
 * the server has told us the real values — which would silently overwrite
 * the server's authoritative volume record.
 */
@Volatile private var serverSettingsReceived: Boolean = false

/** Last known volume (0–100) and mute state from ServerSettings */
@Volatile private var currentVolumePct: Int = 100
@Volatile private var currentMuted: Boolean = false
```

### Step 1 — Record `received` timestamp

When reading a message from the socket, stamp `received` **as soon as the 26-byte header is fully read**, before reading the audio payload.

```kotlin
fun readMessage(inputStream: InputStream): SnapMessage {
    val headerBytes = ByteArray(26)
    inputStream.readFully(headerBytes)  // blocks until all 26 bytes arrive

    // Stamp arrival time immediately — before reading the payload
    val nowUs = System.nanoTime() / 1000L    // nanoseconds → microseconds
    val receivedSec  = (nowUs / 1_000_000L).toInt()
    val receivedUsec = (nowUs % 1_000_000L).toInt()

    val buf = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
    val type       = buf.getShort(0).toInt() and 0xFFFF
    val id         = buf.getShort(2).toInt() and 0xFFFF
    val sentSec    = buf.getInt(6)
    val sentUsec   = buf.getInt(10)
    val payloadLen = buf.getInt(22).toLong() and 0xFFFFFFFFL

    val payload = ByteArray(payloadLen.toInt())
    inputStream.readFully(payload)

    return SnapMessage(
        type        = type,
        id          = id,
        sentSec     = sentSec,
        sentUsec    = sentUsec,
        receivedSec = receivedSec,
        receivedUsec= receivedUsec,
        payload     = payload
    )
}
```

> Use `System.nanoTime()` converted to microseconds for a monotonic clock that doesn't jump on NTP adjustments. **Use this same clock** for all `received` timestamps to keep IPDV meaningful.

### Step 2 — Compute IPDV on each WireChunk

Call this from your IO/receive thread for every message of type `2` (WireChunk):

```kotlin
/**
 * Must be called from the IO/receive thread for every WireChunk.
 * sentSec / sentUsec come from the WireChunk `timestamp` field (audio playout time).
 * recvSec / recvUsec come from base.received.* stamped in step 1.
 */
fun onWireChunk(sentSec: Int, sentUsec: Int, recvSec: Int, recvUsec: Int) {
    val recvUs = recvSec.toLong() * 1_000_000L + recvUsec.toLong()
    val sentUs = sentSec.toLong() * 1_000_000L + sentUsec.toLong()

    if (hasPrevChunkTimestamps) {
        val ipdv = Math.abs((recvUs - prevChunkRecvUsec) - (sentUs - prevChunkSentUsec))

        // jitterBuffer is also read from the time-sync thread — must lock
        synchronized(jitterLock) {
            jitterBuffer.addLast(ipdv)
            if (jitterBuffer.size > JITTER_BUFFER_CAPACITY) {
                jitterBuffer.removeFirst()
            }
        }
    }

    // These fields are only written/read from the IO thread — no lock needed
    prevChunkRecvUsec      = recvUs
    prevChunkSentUsec      = sentUs
    hasPrevChunkTimestamps = true
}
```

### Step 3 — Report jitter after each time-sync response

Call this from your time-sync response handler, after processing the `Time` message (type `4`):

```kotlin
/**
 * Called after each Time response is received.
 * Increments the report counter and sends a ClientInfo with jitter stats
 * every JITTER_REPORT_INTERVAL cycles (if enough samples are available).
 */
fun onTimeSyncComplete() {
    jitterReportCounter++
    if (jitterReportCounter < JITTER_REPORT_INTERVAL) return
    jitterReportCounter = 0   // always reset, regardless of sample count

    if (!serverSettingsReceived) return   // wait for real volume/mute state

    val snapshot: List<Long>
    synchronized(jitterLock) {
        if (jitterBuffer.size < 50) return
        snapshot = jitterBuffer.toList()
    }

    val sorted = snapshot.sorted()
    val median = percentile(sorted, 50)
    val p95    = percentile(sorted, 95)

    sendClientInfo(
        volumePct      = currentVolumePct,
        muted          = currentMuted,
        jitterMedianUs = median,
        jitterP95Us    = p95,
        jitterSamples  = sorted.size
    )
}

/**
 * Percentile index formula — must match the server's DoubleBuffer::percentile().
 * Formula: index = floor((size - 1) * p / 100.0)
 */
private fun percentile(sorted: List<Long>, p: Int): Long {
    val idx = ((sorted.size - 1) * p / 100.0).toInt()
    return sorted[idx]
}
```

### Step 4 — Build and send ClientInfo

```kotlin
/**
 * Sends a ClientInfo message (type 7).
 * jitter* parameters are optional — omit them to send a plain volume/mute update.
 */
fun sendClientInfo(
    volumePct: Int,
    muted: Boolean,
    jitterMedianUs: Long? = null,
    jitterP95Us: Long? = null,
    jitterSamples: Int? = null
) {
    // Build JSON payload
    val jsonObj = JSONObject().apply {
        put("volume", volumePct)
        put("muted", muted)
        if (jitterMedianUs != null && jitterP95Us != null && jitterSamples != null) {
            put("jitter_median_us", jitterMedianUs)
            put("jitter_p95_us", jitterP95Us)
            put("jitter_samples", jitterSamples)
        }
    }
    val jsonBytes = jsonObj.toString().toByteArray(Charsets.UTF_8)
    val jsonSize  = jsonBytes.size

    // Typed payload = 4-byte length prefix + JSON bytes
    val payloadSize = 4 + jsonSize

    // Build the 26-byte base header
    val nowUs    = System.nanoTime() / 1000L
    val sentSec  = (nowUs / 1_000_000L).toInt()
    val sentUsec = (nowUs % 1_000_000L).toInt()

    val out = ByteBuffer.allocate(26 + payloadSize).order(ByteOrder.LITTLE_ENDIAN)
    out.putShort(7.toShort())           // type = kClientInfo
    out.putShort(nextMessageId())       // id
    out.putShort(0.toShort())           // refersTo
    out.putInt(sentSec)                 // sent.sec
    out.putInt(sentUsec)                // sent.usec
    out.putInt(0)                       // received.sec (unused for outgoing)
    out.putInt(0)                       // received.usec
    out.putInt(payloadSize)             // size

    // Typed payload
    out.putInt(jsonSize)                // JSON string length prefix
    out.put(jsonBytes)                  // JSON bytes

    send(out.array())
}
```

### Step 5 — Handle ServerSettings

```kotlin
fun onServerSettings(payload: ByteArray) {
    val buf    = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
    val strLen = buf.getInt(0).toLong() and 0xFFFFFFFFL
    val json   = JSONObject(String(payload, 4, strLen.toInt(), Charsets.UTF_8))

    currentVolumePct     = json.optInt("volume", 100)
    currentMuted         = json.optBoolean("muted", false)
    serverSettingsReceived = true

    // apply bufferMs / latency to your audio buffer as before...
}
```

### Step 6 — Reset on reconnect and codec change

```kotlin
/**
 * Call when the TCP connection drops, before attempting to reconnect.
 */
fun resetOnDisconnect() {
    hasPrevChunkTimestamps = false
    jitterReportCounter    = 0
    serverSettingsReceived = false
    synchronized(jitterLock) { jitterBuffer.clear() }
}

/**
 * Call when a CodecHeader message (type 1) is received — a new stream is starting.
 * Do NOT reset serverSettingsReceived here; the server won't resend ServerSettings
 * within the same connection.
 */
fun resetOnCodecHeader() {
    hasPrevChunkTimestamps = false
    jitterReportCounter    = 0
    synchronized(jitterLock) { jitterBuffer.clear() }
}
```

---

## Thread Safety Notes

| Field | Written from | Read from | Synchronization |
|-------|--------------|-----------|-----------------|
| `jitterBuffer` | IO thread | time-sync thread | `synchronized(jitterLock)` |
| `prevChunkRecvUsec` | IO thread | IO thread only | `@Volatile` (single writer) |
| `prevChunkSentUsec` | IO thread | IO thread only | `@Volatile` (single writer) |
| `hasPrevChunkTimestamps` | IO thread | IO thread only | `@Volatile` (single writer) |
| `jitterReportCounter` | time-sync thread | time-sync thread only | none needed |
| `serverSettingsReceived` | parse thread | time-sync thread | `@Volatile` |
| `currentVolumePct` | parse thread | time-sync thread | `@Volatile` |
| `currentMuted` | parse thread | time-sync thread | `@Volatile` |

If all message processing runs on a single `HandlerThread` (including both WireChunk and Time handling), you can drop `@Volatile` on the IO-only fields and simplify the buffer lock to a check-without-lock pattern — but the explicit `synchronized` block is always correct and preferred for clarity.

**Do not run jitter reporting on the main (UI) thread** — the `synchronized` block and list copy are cheap but should not introduce jitter in the UI.

---

## Acceptance Criteria

1. After ~10 seconds of playback, calling `Client.GetTimeStats` via the server's JSON-RPC API returns non-zero `audio_jitter_median_ms` and `audio_jitter_p95_ms` for the Android client's entry.
2. `audio_samples` is between 50 and 200 (bounded by ring buffer capacity).
3. After disconnect + reconnect, `audio_samples` returns to 0 and grows back cleanly.
4. Changing volume on the server does **not** trigger an extra jitter report — only the 5-cycle cadence fires `sendClientInfo`.
5. Connecting to a server running an older version (pre-PR #5) produces no error — the server silently ignores the extra JSON fields.
6. No ANR, no `ConcurrentModificationException`, clean bill of health under Android Studio's Thread Sanitizer / race detector.

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

`audio_jitter_*` and `audio_samples` being non-zero confirms the Android client is reporting correctly.

The `suggested_buffer_ms` value is informational — negative means the estimated jitter exceeds the safety threshold and the buffer could benefit from being increased. No automatic action is taken by the server; your client may optionally display or log it.
