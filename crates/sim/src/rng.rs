//! SplitMix64. Deterministic, seedable, no dependency. Quality is fine for choosing
//! actions; this is not a cryptographic generator.

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed)
    }
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: u64) -> u64 {
        assert!(n > 0, "below(0)");
        self.next_u64() % n
    }
    pub fn chance(&mut self, num: u64, den: u64) -> bool {
        self.below(den) < num
    }
    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        assert!(!items.is_empty(), "pick from empty slice");
        &items[self.below(items.len() as u64) as usize]
    }
}

#[cfg(test)]
mod tests {
    use super::Rng;

    #[test]
    fn same_seed_same_sequence_and_below_is_in_range() {
        let mut a = Rng::new(7);
        let mut b = Rng::new(7);
        let xs: Vec<u64> = (0..8).map(|_| a.next_u64()).collect();
        let ys: Vec<u64> = (0..8).map(|_| b.next_u64()).collect();
        assert_eq!(xs, ys);
        assert_ne!(xs[0], xs[1]);
        let mut c = Rng::new(1);
        for _ in 0..1000 {
            assert!(c.below(5) < 5);
        }
        assert_eq!(c.below(1), 0);
        let mut d = Rng::new(2);
        let hits = (0..10_000).filter(|_| d.chance(1, 4)).count();
        assert!((2_000..3_000).contains(&hits), "{hits}");
        let mut e = Rng::new(3);
        assert!(["a", "b"].contains(e.pick(&["a", "b"])));
    }
}
