//! Listener pose plumbing.
//!
//! The UI thread pushes the fused-IMU quaternion at ~60 Hz; the audio thread
//! reads it once per callback. A seqlock gives wait-free reads with no
//! allocation and no mutex on the RT path.
//!
//! Recenter: `q_r` (the raw quaternion at recenter time) is latched, and the
//! head quat used by the mixer is `q_head = conj(q_now) * q_r`, which maps
//! scene-space directions into head space.

use crate::math::{Quat, Vec3};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

#[derive(Clone, Copy, Debug)]
pub struct Pose {
    /// Scene->head rotation quat (already recentered + predicted).
    pub head: Quat,
    /// Last raw sensor quat (pre-recenter), used by recenter().
    pub raw: Quat,
}

impl Default for Pose {
    fn default() -> Self {
        Pose { head: Quat::IDENTITY, raw: Quat::IDENTITY }
    }
}

/// Seqlock over a Pose. Writers: sensor thread. Readers: audio callback.
pub struct PoseSlot {
    seq: AtomicU64,
    // head.w head.x head.y head.z | raw.w raw.x raw.y raw.z
    data: [AtomicU32; 8],
}

impl Default for PoseSlot {
    fn default() -> Self {
        Self::new()
    }
}

impl PoseSlot {
    pub fn new() -> Self {
        let slot = PoseSlot {
            seq: AtomicU64::new(0),
            data: Default::default(),
        };
        slot.write(Pose::default());
        slot
    }

    pub fn write(&self, p: Pose) {
        let vals = [
            p.head.w, p.head.x, p.head.y, p.head.z,
            p.raw.w, p.raw.x, p.raw.y, p.raw.z,
        ];
        self.seq.fetch_add(1, Ordering::Relaxed); // -> odd
        for (d, v) in self.data.iter().zip(vals.iter()) {
            d.store(v.to_bits(), Ordering::Relaxed);
        }
        std::sync::atomic::fence(Ordering::Release);
        self.seq.fetch_add(1, Ordering::Release); // -> even
    }

    pub fn read(&self) -> Pose {
        loop {
            let s0 = self.seq.load(Ordering::Acquire);
            if s0 & 1 == 1 {
                std::hint::spin_loop();
                continue;
            }
            let mut v = [0f32; 8];
            for (dst, src) in v.iter_mut().zip(self.data.iter()) {
                *dst = f32::from_bits(src.load(Ordering::Relaxed));
            }
            std::sync::atomic::fence(Ordering::Acquire);
            let s1 = self.seq.load(Ordering::Acquire);
            if s0 == s1 {
                return Pose {
                    head: Quat::new(v[0], v[1], v[2], v[3]),
                    raw: Quat::new(v[4], v[5], v[6], v[7]),
                };
            }
        }
    }
}

/// Tracks sensor quat + recenter offset + gyro rate, produces the head quat.
/// Lives on the UI side; pushes into a shared PoseSlot.
pub struct PoseTracker {
    slot: std::sync::Arc<PoseSlot>,
    recenter: Quat,
    raw: Quat,
    angvel: Vec3,
    /// Extra forward prediction in seconds (e.g. measured BT output latency).
    pub predict_secs: f32,
}

impl PoseTracker {
    /// Shared slot so an engine started later reads the same pose stream.
    pub fn slot(&self) -> std::sync::Arc<PoseSlot> {
        self.slot.clone()
    }

    pub fn new(slot: std::sync::Arc<PoseSlot>) -> Self {
        PoseTracker {
            slot,
            recenter: Quat::IDENTITY,
            raw: Quat::IDENTITY,
            angvel: Vec3::ZERO,
            predict_secs: 0.0,
        }
    }

    /// Called by the sensor bridge with the latest fused quaternion and
    /// (optionally) the latest gyro angular velocity in device coords.
    pub fn update(&mut self, w: f32, x: f32, y: f32, z: f32, gx: f32, gy: f32, gz: f32) {
        self.raw = Quat::new(w, x, y, z).normalized();
        self.angvel = Vec3::new(gx, gy, gz);
        let mut head = self.raw.conj().mul(self.recenter).normalized();
        if self.predict_secs > 0.0 {
            // Dead-reckon the head forward by predicted output latency.
            // q_now evolves as q_now * exp(ω_d·dt) (body-rate propagation),
            // so head' = conj(q_now')·q_r = exp(-ω_d·dt) * head — the
            // increment applies in *device* coords with a sign flip.
            let neg = Vec3::new(-self.angvel.x, -self.angvel.y, -self.angvel.z);
            let pred = Quat::from_angvel(neg, self.predict_secs);
            head = pred.mul(head).normalized();
        }
        self.slot.write(Pose { head, raw: self.raw });
    }

    /// Re-issue the current head pose without a new sensor sample (e.g. after
    /// changing predict_secs).
    pub fn refresh(&mut self) {
        self.update(self.raw.w, self.raw.x, self.raw.y, self.raw.z, self.angvel.x, self.angvel.y, self.angvel.z);
    }

    /// Latch the current raw quat as the recenter reference.
    pub fn recenter(&mut self) {
        self.recenter = self.raw;
        self.refresh();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::FRAC_PI_2;
    use std::sync::Arc;

    #[test]
    fn head_turn_right_puts_front_source_on_left() {
        let slot = Arc::new(PoseSlot::new());
        let mut tracker = PoseTracker::new(slot.clone());
        // Recenter at identity.
        tracker.update(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        tracker.recenter();
        // Turn head right: yaw -90 deg about world z.
        let q = Quat::yaw(-FRAC_PI_2);
        tracker.update(q.w, q.x, q.y, q.z, 0.0, 0.0, 0.0);
        let head = slot.read().head;
        // Scene front (+x) should now appear at +y (left) in head coords.
        let d = head.rotate(Vec3::new(1.0, 0.0, 0.0));
        assert!(d.y > 0.99, "expected front source to move left, got {d:?}");
    }

    #[test]
    fn prediction_anticipates_turn() {
        let slot = Arc::new(PoseSlot::new());
        let mut tracker = PoseTracker::new(slot.clone());
        tracker.predict_secs = 0.1;
        // At identity, yawing right at 1 rad/s.
        tracker.update(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0);
        let head = slot.read().head;
        // Predicted head should be rotated further than raw identity ->
        // front source should appear left of center.
        let d = head.rotate(Vec3::new(1.0, 0.0, 0.0));
        assert!(d.y > 0.05, "prediction should push source left, got {d:?}");
    }
}
