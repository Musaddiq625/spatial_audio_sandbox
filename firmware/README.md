# SAS-TAG — ESP32-S3 Physical Beacon Tag

Technical plan for replacing the beacon phone with a self-contained
ESP32-S3 tag. The tag hosts its own Wi-Fi AP, speaks the existing UDP
beacon protocol byte-for-byte, streams a rotation-vector quaternion for
aimed bearing, switches sound kinds via physical buttons, and provides
real distance via 802.11mc Wi-Fi RTT — no mic, no speaker.

## Architecture

```
┌─ ESP32-S3 tag ("SAS-TAG") ─────────────────────────────────┐
│  soft-AP  + FTM responder (802.11mc)                        │
│  UDP stack: SASB announce → SASH wait → SAST telemetry      │
│  BNO085 (I2C) → rotation-vector quat   Buttons → kind flags │
└──────────────┬───────────────────────────┬─────────────────┘
               │ UDP (47290)               │ 802.11mc RTT
               ▼                           ▼
┌─ Pixel 6 Pro (listener) ───────────────────────────────────┐
│  SasLink (announces/telemetry)  WifiRttManager (distance)  │
│  beacon_tracker: aimed bearing + rtt distance fusion        │
│  sas_engine (Rust): setSourcePosition → binaural out        │
└─────────────────────────────────────────────────────────────┘
```

Why tag-as-AP: Android can only RTT-range **AP-class responders**, and a
2-device network eliminates AP isolation / subnet issues entirely.
Trade-off: the phone has no internet while joined to the tag.

## Wire protocol (must match `lib/link.dart` exactly)

Port `47290` UDP. All packet headers are big-endian; telemetry floats are
**little-endian** (mixed endianness — watch this in firmware).

| Packet | Magic | Layout |
|--------|-------|--------|
| `SASB` announce | `0x53415342` | magic(4) id(2) flags(1) nameLen(1) name(n≤24) |
| `SASH` head reply | `0x53415348` | magic(4) only — listener→tag ack |
| `SAST` telemetry | `0x53415354` | magic(4) id(2) seq(4) sentMs(4) flags(2) quat[4]f32-LE(16) gyro[3]f32-LE(12) nameLen(1) name(n≤24) |
| `SASD` range delay | `0x53415344` | magic(4) id(2) delayNanos i64-BE(8) — unused (no acoustics) |

Flags byte/bitfield: low nibble = kind index (0=bee,1=rain,2=pad,3=tone,
4=noise), bit `0x10` = `apHost` (tag sets it — it *is* the AP).

### Tag link state machine (mirror of `SasBeacon`)

- `ANNOUNCING`: broadcast `SASB` @1Hz to subnet broadcast + `255.255.255.255`
- On `SASH` from `addr` → `LINKED`: unicast `SAST` @30Hz to `addr:47290`
- While `LINKED`: keepalive `SASB` to listener every 4s; a received `SASH`
  refreshes `_lastAck`; >8s silence → back to `ANNOUNCING`
- Tag only ever announces/unicasts — no probing needed (no manual-IP UX)

## Shopping list

### Core rig (~$25–40)

| Part | Spec | ~Price |
|------|------|--------|
| ESP32-S3 dev board | "ESP32-S3-DevKitC-1" N8R8/N16R8 — **must be S3/S2/C3; original ESP32 can't FTM-respond** | $8–15 |
| IMU breakout | BNO085/BNO086 9-DOF I2C (rotation vector) | $8–25 |
| Tactile buttons ×4–6 | 6×6mm momentary, breadboard-friendly | $1–3 |
| Breadboard | half-size 400-pt | $3–5 |
| Jumper wires | male-to-male | $2–4 |
| USB-C cable | **data** cable (not charge-only) | have |

### IMU alternatives

| Part | ~Price | Trade-off |
|------|--------|-----------|
| BNO055 | $8–20 | Older chip, simpler I2C register protocol, noisier fusion |
| MPU6050/9250 | $2–6 | No HW fusion — Madgwick/Mahony in firmware, more drift |

### Optional (untethered build)

18650+holder+TP4056+MT3608 boost or LiPo (~$10–15), perfboard, slide
switch, status LED (announce vs linked blink), enclosure (~$20 total).

## Implementation

### Firmware (`firmware/` — ESP-IDF project)

FTM responder APIs (`esp_wifi_ftm_init_responder`) live in IDF, not
Arduino core → ESP-IDF.

- `app_main.c` — soft-AP `SAS-TAG` (open or fixed WPA2), FTM responder on
  the AP interface, task startup
- `sas_proto.c` — announce/link/telemetry/keepalive state machine above
- `imu.c` — BNO085 SHTP-over-I2C → rotation vector quat
  (BNO055: direct register reads; MPU6050: Madgwick)
- `buttons.c` — GPIO + debounce → kind index → telemetry flags

### Android listener (`MainActivity.kt`)

- `MethodChannel('dev.sas.spatial_audio_sandbox/rtt')`: `startRanging`,
  `stopRanging`
- `EventChannel('dev.sas.spatial_audio_sandbox/rtt_events')`: distance
  stream → Dart
- `WifiManager.startScan` → find tag `ScanResult` (`is80211mcResponder`)
  → `ResponderConfig` → `WifiRttManager.startRanging`
- Manifest + runtime permission: `NEARBY_WIFI_DEVICES` (API 33+),
  `ACCESS_FINE_LOCATION` (older) — same flow as mic permission

### Dart (small)

- `lib/rt_ranging.dart` (new) — channel wrapper → `Stream<double>` m
- `lib/beacon_tracker.dart` — `rttM` input beside `acousticM`, same
  sanity clamp + stale-fade; mode label `rtt`
- `lib/sandbox_page.dart` — start ranging when linked beacon is on the
  tag's AP; feed `tracker.rttM`; label `rtt X.Xm — live` + manual override
- `lib/link.dart`, `beacon_page.dart` — unchanged (phone beacon stays
  as the dev path; multiple `beaconId`s coexist)

## Verification

- [ ] `fvm flutter test` + `fvm flutter analyze` green
- [ ] `SAS-TAG` SSID up → Pixel joins → auto-link/`link sas-tag` works
- [ ] Point tag at Pixel → aimed bearing tracks on radar
- [ ] Button press → listener kind switches live
- [ ] `adb logcat` RTT distances → `rtt X.Xm` on dot; walk tag → tracks
- [ ] Motorola phone-beacon still works alongside
- [ ] Tracker test: rtt feed beats manual, stale reverts

## Risks

- FTM responder ↔ `RttManager` is proven-but-fiddly (channel/regdomain);
  manual slider remains the fallback — nothing is blocked.
- No internet on the phone while joined to `SAS-TAG`.
- RTT ≈ 1m indoor accuracy (UWB/DWM3000 is the ~10cm upgrade path).
- Firmware is the bulk of the work; Dart/Android changes are small.
- Dart side can be fully built before hardware arrives (`fake_beacon`
  simulates tag traffic; only RTT needs the real tag).
