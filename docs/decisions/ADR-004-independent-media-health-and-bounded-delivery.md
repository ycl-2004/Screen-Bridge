# ADR-004: Independent Media Health and Bounded Delivery

- Status: Accepted
- Date: 2026-08-15

## Context

Screen Bridge previously treated any received byte as proof that the picture was
healthy. Audio or heartbeat traffic could therefore hide a stalled video
decoder or renderer. Conversely, ScreenCaptureKit may emit no new complete frame
while a desktop is visually static, so using frame arrival alone would report a
healthy static screen as disconnected.

The sender also let P2P and wired video writes accumulate without
completion backpressure. Those routes are usually fast, but a transient receiver
stall can still grow Network.framework's queue and turn a short interruption
into seconds of latency.

## Decision

- The sender emits an explicit media heartbeat independently of changed video
  frames.
- The receiver tracks heartbeat, video access-unit arrival, successful decode,
  and successful renderer enqueue as separate timestamps.
- A session fails with a specific transport, first-frame, decoder, or renderer
  reason. Once a frame has rendered, a fresh heartbeat keeps an unchanged
  desktop healthy.
- Decoder and renderer stall detection becomes eligible only after that stage
  has completed at least one frame. During startup, the first-frame deadline is
  authoritative; `.distantPast` initialization sentinels must not turn the
  normal first access-unit → decode → main-thread render handoff into an
  immediate false stall.
- Screen capture accepts only valid sample buffers whose ScreenCaptureKit frame
  status is `complete`.
- Shared infrastructure paths permit two in-flight video packets. Verified
  AWDL and cable paths permit four. Every path retains at most one newest
  recovery keyframe, and P-frames are dropped once its bounded window is full.
- Auxiliary audio sends from its own user-interactive serial queue. It permits
  one in-flight AAC packet plus seven pending FIFO packets (about 171 ms total
  at 48 kHz). When full it drops the oldest waiting packet and records queue
  depth, drop count, and send-latency EWMA. Media heartbeats still permit only
  one in-flight write, so no media class can grow an unbounded
  Network.framework queue.
- Protocol v3 prefixes each AAC payload with sequence, sample time, sample
  count, codec, and flags. The receiver rejects malformed headers and reports
  sequence gaps instead of treating missing audio as unknowable timing noise.
- The receiver starts and resumes after five decoded AAC buffers (~107 ms),
  caps decoded audio at ten buffers, and returns to buffering whenever playback
  drains to zero. Its AudioSession requests 48 kHz and a 10 ms hardware buffer
  before activation, then records the values iOS actually granted.
- Receiver queue depth retires a decoded buffer only from
  `AVAudioPlayerNodeCompletionDataRendered`. The convenience `scheduleBuffer`
  completion is equivalent to `dataConsumed`, which Apple documents may run
  before rendering begins or before the buffer has completely played. Each
  playback reset also advances a generation so delayed completions from a
  stopped engine cannot consume buffers scheduled by a later connection.
- Send-completion latency and bounded-queue drops feed a pure adaptive bitrate
  policy. The user-selected quality is the upper bound and 5 Mbps is the normal
  lower bound.
- The sender reports **Video Throughput** from compressed video bytes admitted
  to the Network.framework send window divided by the actual elapsed sampling
  interval. It is an aggregate application-delivery rate across displays, not
  physical link capacity and not an audio/control traffic counter.
- Audio owns a separate authenticated transport. Chrome process changes or
  auxiliary transport failures rebuild only that audio branch; they never
  rebuild the virtual display or change the receiver's global video state.
- Each display/capture incarnation has a generation. Delayed display polling,
  encoder callbacks, and send completions are ignored after a rebuild changes
  that generation.

## Consequences

Static content no longer causes a false timeout, while bytes that never decode
or render no longer mask a frozen picture. Memory and latency stay bounded even
when a nominally fast direct route stalls. Congestion may reduce temporary
picture quality or drop motion frames, which is an intentional trade for keeping
the newest screen state responsive.

The first-frame deadline still tears down a session that never renders, but a
freshly authenticated session is not judged by steady-state decoder/renderer
stall rules until those stages have first demonstrated progress. This removes a
startup race without weakening established-session stall detection.

The health, bitrate, audio FIFO, timed-packet framing, sequence tracking, and
jitter-buffer transitions are pure and covered by shared tests. Audio now pays
about 107 ms of startup/recovery buffering and can accumulate at most about
171 ms on the sender; that bounded latency is the explicit trade for continuity.
Rendered-completion accounting removes false queue depletion without enlarging
that fixed jitter buffer or reducing audio quality. Generation isolation makes
stop/reconnect callbacks harmless. The throughput display remains useful for
relative workload observation but does not imply link speed or stability.

Apple API contracts used for the receiver accounting:

- https://developer.apple.com/documentation/avfaudio/avaudioplayernode/schedulebuffer(_:completioncallbacktype:completionhandler:)
- https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/datarendered

Real-device validation is still required after playback-policy changes and to
tune thresholds across AWDL, router Wi-Fi, and cable paths.
