//! Minimal vec3/quat math, no deps.
//!
//! Scene/head space is right-handed: +x = front, +y = left, +z = up.
//! Azimuth follows SOFA convention: 0 deg = front, +90 deg = left.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const ZERO: Vec3 = Vec3 { x: 0.0, y: 0.0, z: 0.0 };
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }
    pub fn norm(self) -> f32 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }
    pub fn sub(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

/// Unit quaternion (w, x, y, z). `rotate(v)` applies q * v * conj(q).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quat {
    pub w: f32,
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Quat {
    pub const IDENTITY: Quat = Quat { w: 1.0, x: 0.0, y: 0.0, z: 0.0 };

    pub const fn new(w: f32, x: f32, y: f32, z: f32) -> Self {
        Self { w, x, y, z }
    }

    pub fn conj(self) -> Quat {
        Quat::new(self.w, -self.x, -self.y, -self.z)
    }

    pub fn mul(self, o: Quat) -> Quat {
        Quat::new(
            self.w * o.w - self.x * o.x - self.y * o.y - self.z * o.z,
            self.w * o.x + self.x * o.w + self.y * o.z - self.z * o.y,
            self.w * o.y - self.x * o.z + self.y * o.w + self.z * o.x,
            self.w * o.z + self.x * o.y - self.y * o.x + self.z * o.w,
        )
    }

    pub fn normalized(self) -> Quat {
        let n = (self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z)
            .sqrt()
            .max(1e-9);
        Quat::new(self.w / n, self.x / n, self.y / n, self.z / n)
    }

    /// Rotate vector v by this quaternion: q * v * conj(q).
    pub fn rotate(self, v: Vec3) -> Vec3 {
        // Expanded q*v*q^-1 without constructing quats for v.
        let tx = 2.0 * (self.y * v.z - self.z * v.y);
        let ty = 2.0 * (self.z * v.x - self.x * v.z);
        let tz = 2.0 * (self.x * v.y - self.y * v.x);
        Vec3::new(
            v.x + self.w * tx + (self.y * tz - self.z * ty),
            v.y + self.w * ty + (self.z * tx - self.x * tz),
            v.z + self.w * tz + (self.x * ty - self.y * tx),
        )
    }

    /// Rotation about +z axis (yaw) by `rad` radians.
    pub fn yaw(rad: f32) -> Quat {
        let h = rad * 0.5;
        Quat::new(h.cos(), 0.0, 0.0, h.sin())
    }

    /// Small-angle rotation from an angular velocity vector (rad/s) over dt seconds.
    /// Used by gyro dead-reckoning prediction.
    pub fn from_angvel(omega: Vec3, dt: f32) -> Quat {
        let half = 0.5 * dt;
        Quat::new(1.0, omega.x * half, omega.y * half, omega.z * half).normalized()
    }
}

/// Direction in spherical coords: az/el in radians, dist in meters.
#[derive(Clone, Copy, Debug)]
pub struct Spherical {
    pub az: f32,
    pub el: f32,
    pub dist: f32,
}

impl Spherical {
    /// Convert a head-relative direction (x=front, y=left, z=up) to
    /// SOFA-style spherical coords. az: +left, el: +up.
    pub fn from_vec3(v: Vec3) -> Self {
        let horiz = (v.x * v.x + v.y * v.y).sqrt();
        Spherical {
            az: v.y.atan2(v.x),
            el: v.z.atan2(horiz.max(1e-9)),
            dist: v.norm(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::FRAC_PI_2;

    #[test]
    fn yaw_rotates_front_to_left() {
        // +90 deg yaw about z maps +x (front) onto +y (left).
        let v = Quat::yaw(FRAC_PI_2).rotate(Vec3::new(1.0, 0.0, 0.0));
        assert!((v.x).abs() < 1e-5 && (v.y - 1.0).abs() < 1e-5);
    }

    #[test]
    fn spherical_az_left_is_positive() {
        let s = Spherical::from_vec3(Vec3::new(0.0, 1.0, 0.0));
        assert!((s.az - FRAC_PI_2).abs() < 1e-5);
    }
}
