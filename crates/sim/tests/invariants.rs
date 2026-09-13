//! R2: random operation sequences with every invariant checked after every step.
//! Default is quick; SIM_SEEDS and SIM_STEPS scale it up for a long run.
use otter_sim::Sim;

fn env(name: &str, default: usize) -> usize {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

#[test]
fn random_sequences_violate_no_invariant() {
    let seeds = env("SIM_SEEDS", 60);
    let steps = env("SIM_STEPS", 120);
    for seed in 0..seeds as u64 {
        if let Err(failure) = Sim::run(seed, 3, steps) {
            panic!("{failure}");
        }
    }
}

#[test]
fn every_run_ends_converged_after_settle() {
    for seed in 100..110u64 {
        let mut sim = Sim::new(seed, 2);
        for i in 0..2 {
            sim.apply(otter_sim::Action::Subscribe {
                client: i,
                channel: "a".into(),
            })
            .unwrap();
        }
        for _ in 0..80 {
            sim.step().unwrap();
        }
        for i in 0..2 {
            sim.apply(otter_sim::Action::Restart { client: i }).unwrap();
        }
        sim.settle();
        sim.check().unwrap_or_else(|e| panic!("seed {seed}: {e}"));
    }
}
