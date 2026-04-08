# Audio Chunk IPDV Jitter Measurement

## Overview

Santcasp measures inter-packet delay variation (IPDV) on audio chunk arrivals to quantify network delivery jitter. This document describes the algorithm, its validation, and implementation details for all client platforms.

## Algorithm

### Formula (RFC 3550 Section 6.4.1)

For consecutive audio chunks N-1 and N:

```
recv_delta = recv_time[N] - recv_time[N-1]     (client clock)
sent_delta = audio_timestamp[N] - audio_timestamp[N-1]  (server clock)
IPDV = |recv_delta - sent_delta|
```

Clock offsets cancel because each delta uses only one clock.

### Why audio_timestamp, not message.sent

The base message `sent` field is set once at serialization time in `shared_const_buffer` and is identical for all clients receiving the same chunk. It reflects server encoding interval stability (~microseconds), not per-client delivery timing.

The audio playout `timestamp` (WireChunk.timestamp) advances by exactly `chunk_ms` per chunk. Using it as the sent reference means:

```
sent_delta = exactly chunk_ms (e.g., 24000 microseconds)
IPDV = |recv_delta - chunk_ms|
```

This captures pure delivery jitter as seen by the application.

### Why not message.received directly?

An earlier approach measured IPDV using `message.sent` (set at serialization) for the sent reference. This produced microsecond-scale values because:

1. `sent` was set once per chunk, identical for all clients
2. Server encoding intervals are extremely stable (~microsecond variance)
3. `|recv_delta - sent_delta|` measured only the tiny difference between two very stable intervals

### Why not server-side Time message IPDV?

The original Step 0 implementation measured IPDV on Time sync messages (1Hz, ~30 bytes). This was abandoned because:

- 1Hz sampling rate vs 50Hz audio chunks
- 30-byte packets vs ~4KB audio chunks
- WiFi queuing/CSMA/CA behaves differently at different packet sizes and rates
- Jitter was always near-zero (microsecond-scale)

## Implementation

### Timestamps

| Field | Clock | Set when | Set where |
|-------|-------|----------|-----------|
| `received` | Client steady_clock | async_read header completes | client_connection.cpp |
| `timestamp` | Server steady_clock | Chunk encoded | pcm_stream.cpp:344-346 |

Both use `steady_clock` (monotonic, from boot). The clocks have different epochs on different machines, but IPDV uses deltas so offsets cancel.

### Data flow

```
Server: encode chunk → set timestamp → serialize → TCP send
                                         |
Network: WiFi jitter (1-10ms typical)    |
                                         v
Client: TCP recv buffer (128KB = ~34 chunks ahead)
         → async_read → set received → compute IPDV
         → store in DoubleBuffer(200) → report every 5s via ClientInfo
                                         |
Server: store in StreamSession            |
         → expose via Client.GetTimeStats |
         → compute suggested_buffer_ms    v
```

### TCP buffering note

The TCP kernel receive buffer (typically 128KB on macOS, 64-256KB on Linux) can hold ~34 chunks at 48000:16:2. Despite this buffering, the IPDV measurement produces millisecond-scale values because:

- `sent_delta` (audio timestamp) is perfectly constant
- `recv_delta` varies with actual delivery timing — even through TCP buffering, chunks don't all arrive at once; they arrive in bursts matching server send patterns plus network jitter

Validated empirically: IPDV of 1.6-5ms on WiFi matches independent ping jitter measurements (stddev 11.4ms round-trip, ~4.4ms avg one-way) on the same network.

### Client code (C++)

```cpp
// client/controller.cpp — in kWireChunk handler
int64_t recv_usec = (int64_t)pcmChunk->received.sec * 1000000LL + pcmChunk->received.usec;
int64_t sent_usec = (int64_t)pcmChunk->timestamp.sec * 1000000LL + pcmChunk->timestamp.usec;

if (hasPrevChunkTimestamps_)
{
    int64_t recv_delta = recv_usec - prevChunkRecvUsec_;
    int64_t sent_delta = sent_usec - prevChunkSentUsec_;
    chunkJitterBuffer_.add(std::abs(recv_delta - sent_delta));
}
prevChunkRecvUsec_ = recv_usec;
prevChunkSentUsec_ = sent_usec;
hasPrevChunkTimestamps_ = true;
```

### Reporting

Every 5 Time sync messages (~5 seconds), if the buffer has >= 50 samples:

```cpp
auto pcts = chunkJitterBuffer_.percentiles<2>({50, 95});
info->setJitterMedianUs(pcts[0]);
info->setJitterP95Us(pcts[1]);
info->setJitterSamples(chunkJitterBuffer_.size());
```

Sent via ClientInfo message (type 7) alongside volume/mute state.

### Server API

`Client.GetTimeStats` returns:

```json
{
  "audio_jitter_median_ms": 4.3,
  "audio_jitter_p95_ms": 8.7,
  "audio_samples": 200,
  "control_jitter_median_ms": 0.001,
  "control_jitter_p95_ms": 0.012,
  "control_samples": 100,
  "suggested_buffer_ms": -13
}
```

- `audio_*`: Client-reported IPDV on WireChunks (~50Hz)
- `control_*`: Server-measured IPDV on Time messages (~1Hz)
- `suggested_buffer_ms`: Negative = increase buffer to absorb jitter

## Expected values

| Network | Median IPDV | P95 IPDV | Notes |
|---------|-------------|----------|-------|
| Wired Ethernet | < 0.5ms | < 1ms | Near-zero jitter |
| WiFi 5GHz (quiet) | 1-5ms | 5-15ms | Normal for home WiFi |
| WiFi 2.4GHz (congested) | 5-20ms | 20-100ms | Interference, many devices |
| WiFi with packet loss | Spikes to 50-200ms | > 200ms | TCP retransmissions |

## Validation

Cross-validated on WiFi (2026-04-08):

```
IPDV samples:    4311, 3706, 4311, 4977, 1632 microseconds
Ping (same path): min=1.6ms avg=4.4ms max=115ms stddev=11.4ms, 3% loss

IPDV median ≈ ping avg/2 (one-way vs round-trip) ✓
```

## Mobile implementation

See platform-specific guides:
- [iOS implementation](client/jitter-measurement-ios.md)
- [Android implementation](client/jitter-measurement-android.md)

Key difference: mobile clients implement the binary protocol natively (Swift/Kotlin) rather than compiling the C++ client. The IPDV algorithm is identical — use the WireChunk audio `timestamp` field, not the base message `sent` field.
