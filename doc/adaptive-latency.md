# Adaptive Latency — Santcasp Core Feature

## Vision

Snapcast clients on different networks experience different levels of jitter. A Raspberry Pi on Ethernet has sub-millisecond jitter; a phone on WiFi might have 5-50ms. Today, operators manually tune `Client.SetLatency` per device — a tedious process that breaks when network conditions change.

Santcasp's adaptive latency feature makes this automatic: the system measures real audio delivery jitter per client and adjusts playback buffers to match, ensuring glitch-free audio with minimal latency.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      SERVER                              │
│                                                          │
│  ┌─────────┐    ┌──────────────┐    ┌─────────────────┐  │
│  │ Encoder │───>│ StreamServer │───>│ StreamSession    │  │
│  │ (PCM)   │    │ (fan-out)    │    │ per client:      │  │
│  └─────────┘    └──────────────┘    │  clientJitter_   │  │
│                                     │  latencyBuffer_  │  │
│                                     └────────┬────────┘  │
│                                              │           │
│  ┌─────────────────────┐    ┌────────────────▼────────┐  │
│  │ Client.GetTimeStats │<───│ ClientGetTimeStatsReq   │  │
│  │ (JSON-RPC)          │    │  suggested_buffer_ms    │  │
│  └─────────────────────┘    └─────────────────────────┘  │
│                                                          │
│  ┌─────────────────────┐                                 │
│  │ Auto-Tuner [FUTURE] │ ← reads jitter, pushes         │
│  │ ServerSettings       │   adjusted latency per client  │
│  └─────────────────────┘                                 │
└──────────────────────────────────────────────────────────┘
         │                              ▲
         │ WireChunks (TCP)             │ ClientInfo (jitter stats)
         ▼                              │
┌──────────────────────────────────────────────────────────┐
│                      CLIENT                              │
│                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────┐  │
│  │ Connection   │───>│ Controller   │───>│ Stream     │  │
│  │ TCP receive  │    │ IPDV calc    │    │ playback   │  │
│  │ (128KB buf)  │    │ per chunk    │    │ buffer     │  │
│  └──────────────┘    └──────┬───────┘    └────────────┘  │
│                             │                            │
│                     ┌───────▼───────┐                    │
│                     │ DoubleBuffer  │                    │
│                     │ (200 samples) │                    │
│                     │ median, P95   │                    │
│                     └───────┬───────┘                    │
│                             │ every ~5s                   │
│                     ┌───────▼───────┐                    │
│                     │ ClientInfo    │                    │
│                     │ msg (type 7)  │───> to server      │
│                     └───────────────┘                    │
└──────────────────────────────────────────────────────────┘
```

## Implementation Status

### Complete

| Component | Location | Description |
|-----------|----------|-------------|
| IPDV measurement | `client/controller.cpp` | Per-chunk jitter using audio playout timestamps (RFC 3550) |
| Jitter reporting | `client/controller.cpp` | Median + P95 sent via ClientInfo every ~5s |
| ClientInfo extension | `common/message/client_info.hpp` | `jitter_median_us`, `jitter_p95_us`, `jitter_samples` fields |
| Server storage | `server/stream_session.hpp` | `ClientJitter` struct with thread-safe access |
| JSON-RPC endpoint | `server/control_requests.cpp` | `Client.GetTimeStats` returns audio + control jitter |
| Buffer suggestion | `server/control_requests.cpp` | `suggested_buffer_ms` from P95 × 1.5 safety factor |
| Control-path jitter | `server/stream_session.hpp` | IPDV on Time messages (1Hz, secondary metric) |

### Pending — Step 2: Auto-Tuner

The server computes `suggested_buffer_ms` but nothing acts on it. The missing piece:

```
Server periodic check (every ~30s):
  for each client with auto_latency enabled:
    if |suggested_buffer_ms - current_latency| > threshold (5ms):
      new_latency = 0.8 * current + 0.2 * suggested   (exponential filter)
      push ServerSettings with new latency
```

Configuration (proposed):
```ini
[server]
auto_latency = false          # opt-in, default off
auto_latency_interval = 30    # seconds between recalculations
auto_latency_threshold = 5    # ms minimum change to trigger update
auto_latency_safety = 1.5     # multiplier on P95 jitter
```

### Pending — Mobile Clients

Implementation guides written, awaiting native client development:
- [iOS implementation guide](client/jitter-measurement-ios.md)
- [Android implementation guide](client/jitter-measurement-android.md)

## How the Measurement Works

### The Problem

Measuring network jitter from an application running over TCP is non-trivial:

1. **Server timestamps are shared**: The base message `sent` field is set once at serialization and is identical for all clients. It measures server encoding stability, not per-client delivery.

2. **TCP buffers absorb jitter**: The kernel TCP receive buffer (typically 128KB) holds ~34 audio chunks. The application reads from a full buffer — `recv()` timing reflects processing speed, not network arrival.

3. **Control messages are too infrequent**: Time sync messages (1Hz, 30 bytes) don't represent audio traffic patterns (50Hz, ~4KB).

### The Solution

Use the WireChunk audio playout `timestamp` as the sent reference:

```
sent_delta = audio_timestamp[N] - audio_timestamp[N-1] = exactly chunk_ms
recv_delta = received_time[N] - received_time[N-1] = chunk_ms ± jitter
IPDV = |recv_delta - sent_delta| = |delivery jitter|
```

The audio timestamp advances by exactly `chunk_ms` per chunk (e.g., 24ms for 48000:16:2). Any variation in `recv_delta` from this perfect interval IS delivery jitter.

Despite TCP buffering, this works because chunks don't arrive simultaneously — they arrive in bursts matching server send patterns plus network jitter. The IPDV captures this variation.

### Validation

Cross-validated on WiFi (2026-04-08):

| Method | Result |
|--------|--------|
| IPDV (our measurement) | median 4.2ms, P95 16ms |
| ping -i 0.024 (independent) | avg 4.4ms RTT, stddev 11.4ms |
| Snapweb dashboard | Jitter (audio): 4.2ms, P95: 16ms |

IPDV median ≈ ping avg / 2 (one-way vs round-trip). Results are consistent.

See [jitter-measurement.md](jitter-measurement.md) for the full algorithm reference.

## API

### Client.GetTimeStats

```json
{
  "id": 9,
  "jsonrpc": "2.0",
  "method": "Client.GetTimeStats",
  "params": {"id": "d6:fd:f1:da:eb:7d"}
}
```

Response:
```json
{
  "id": 9,
  "jsonrpc": "2.0",
  "result": {
    "id": "d6:fd:f1:da:eb:7d",
    "audio_jitter_median_ms": 4.2,
    "audio_jitter_p95_ms": 16.0,
    "audio_samples": 200,
    "control_jitter_median_ms": 0.003,
    "control_jitter_p95_ms": 0.016,
    "control_samples": 100,
    "suggested_buffer_ms": -24
  }
}
```

| Field | Source | Rate | Description |
|-------|--------|------|-------------|
| `audio_jitter_*` | Client-reported | ~50Hz chunks | Real audio delivery jitter |
| `control_jitter_*` | Server-measured | ~1Hz Time msgs | Network health indicator |
| `suggested_buffer_ms` | Computed | — | Negative = increase buffer by this amount |

### Interpreting suggested_buffer_ms

- `0` → jitter is within acceptable range, no adjustment needed
- `-24` → client needs ~24ms more buffer to absorb P95 jitter spikes
- Applied via `Client.SetLatency` (manual) or auto-tuner (future)

## Expected Jitter Values

| Network | Median | P95 | Action |
|---------|--------|-----|--------|
| Wired Ethernet | < 0.5ms | < 1ms | No adjustment needed |
| WiFi 5GHz (quiet) | 1-5ms | 5-15ms | Small buffer increase |
| WiFi 2.4GHz (busy) | 5-20ms | 20-100ms | Significant buffer increase |
| WiFi with packet loss | Spikes > 50ms | > 200ms | Warning; buffer may not help |

## History

This feature evolved through several iterations:

1. **Server-side RTT tracking** — measured Time message RTT. Abandoned: `steady_clock` offset between machines made values meaningless.

2. **Server-side IPDV on Time messages** — correct math (RFC 3550), but 1Hz/30-byte packets don't represent audio traffic. Jitter always near-zero.

3. **Client-side IPDV using message.sent** — moved measurement to client on actual audio chunks. But `sent` was set once at serialization, identical for all clients. Measured server encoding stability (~4μs), not network jitter.

4. **Client-side IPDV using audio timestamp** (current) — uses the perfectly-spaced audio playout timestamp as the reference. Produces millisecond-scale values validated against independent measurements.

Each iteration's failure informed the next. The key insight: the only timestamp that is both perfectly regular AND independent of serialization timing is the audio playout timestamp embedded in the WireChunk payload.

## Differences from Upstream Snapcast

Upstream snapcast has no jitter measurement or adaptive latency capability. All latency adjustment is manual via `Client.SetLatency`. This feature is the core differentiator of the santcasp fork.

| Capability | Upstream | Santcasp |
|------------|----------|----------|
| Latency adjustment | Manual only | Manual + suggested + auto (future) |
| Jitter measurement | None | IPDV on audio chunks |
| Per-client diagnostics | None | `Client.GetTimeStats` |
| Buffer recommendation | None | `suggested_buffer_ms` |
| Snapweb jitter display | None | Live median + P95 |
