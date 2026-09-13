//! Random stepping. One weighted choice per step; every choice comes from the seeded
//! RNG so a seed reproduces a run.
use crate::{Action, MutationSpec, Sim};
use std::fmt;

const CHANNELS: [&str; 3] = ["a", "b", "c"];

pub struct Failure {
    pub seed: u64,
    pub step: usize,
    pub error: String,
    pub trace: Vec<Action>,
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "seed {} failed at step {}: {}",
            self.seed, self.step, self.error
        )?;
        for (i, a) in self.trace.iter().enumerate() {
            writeln!(f, "  {i:4}  {a:?}")?;
        }
        Ok(())
    }
}

impl Sim {
    fn running(&self) -> Vec<usize> {
        (0..self.clients.len()).filter(|&i| self.is_up(i)).collect()
    }
    fn crashed(&self) -> Vec<usize> {
        (0..self.clients.len())
            .filter(|&i| !self.is_up(i))
            .collect()
    }
    fn pick_channel(&mut self) -> String {
        self.rng.pick(&CHANNELS).to_string()
    }
    fn choose(&mut self) -> Option<Action> {
        let running = self.running();
        let roll = self.rng.below(100);
        let client = if running.is_empty() {
            None
        } else {
            Some(*self.rng.pick(&running))
        };
        Some(match roll {
            0..20 => {
                let client = client?;
                let mutation = self.pick_mutation(client);
                Action::Enqueue { client, mutation }
            }
            20..32 => Action::Freeze { client: client? },
            32..46 => {
                let channel = self.pick_channel();
                Action::Pull {
                    client: client?,
                    channel,
                }
            }
            46..68 => Action::Deliver,
            68..72 => Action::Drop,
            72..76 => Action::Duplicate,
            76..81 => Action::Hold,
            81..84 => {
                let n = self.net.len() as u64;
                if n < 2 {
                    Action::Deliver
                } else {
                    Action::Swap {
                        i: self.rng.below(n) as usize,
                        j: self.rng.below(n) as usize,
                    }
                }
            }
            84..86 => Action::Crash { client: client? },
            86..90 => {
                let crashed = self.crashed();
                if crashed.is_empty() {
                    Action::Deliver
                } else {
                    Action::Restart {
                        client: *self.rng.pick(&crashed),
                    }
                }
            }
            90..92 => {
                let channel = self.pick_channel();
                Action::Subscribe {
                    client: client?,
                    channel,
                }
            }
            92 => {
                let channel = self.pick_channel();
                Action::Unsubscribe {
                    client: client?,
                    channel,
                }
            }
            93..96 => {
                if self.known_entries.is_empty() {
                    return Some(Action::Deliver);
                }
                let id = self.rng.pick(&self.known_entries).clone();
                let text = if self.rng.chance(1, 5) {
                    None
                } else {
                    Some(format!("s{}", self.rng.below(1000)))
                };
                let mut channels = vec![self.pick_channel()];
                if self.rng.chance(1, 2) {
                    let c = self.pick_channel();
                    if !channels.contains(&c) {
                        channels.push(c);
                    }
                }
                Action::ServerChange {
                    key: format!("Entry:{id}"),
                    text,
                    channels,
                }
            }
            96..98 => Action::RejectNext {
                code: "sim.denied".into(),
            },
            98 => Action::FailNext,
            _ => {
                if !self.generate_direct || self.known_entries.is_empty() {
                    return Some(Action::Deliver);
                }
                let client = client?;
                let id = self.rng.pick(&self.known_entries).clone();
                self.next_id += 1;
                Action::Direct {
                    client,
                    key: format!("Entry:{id}"),
                    text: format!("d{}", self.next_id),
                }
            }
        })
    }
    fn pick_mutation(&mut self, _client: usize) -> MutationSpec {
        let roll = self.rng.below(6);
        match roll {
            0 | 1 => {
                self.next_id += 1;
                let id = format!("e{}", self.next_id);
                self.known_entries.push(id.clone());
                MutationSpec::CreateEntry {
                    id,
                    text: format!("t{}", self.rng.below(1000)),
                }
            }
            2 if !self.known_entries.is_empty() => {
                let id = self.rng.pick(&self.known_entries).clone();
                MutationSpec::Edit {
                    id,
                    text: format!("t{}", self.rng.below(1000)),
                }
            }
            3 if !self.known_entries.is_empty() => {
                let id = self.rng.pick(&self.known_entries).clone();
                MutationSpec::DeleteEntry { id }
            }
            4 if !self.known_entries.is_empty() => {
                self.next_id += 1;
                let id = format!("c{}", self.next_id);
                let entry = self.rng.pick(&self.known_entries).clone();
                self.known_comments.push(id.clone());
                MutationSpec::CreateComment {
                    id,
                    entry,
                    text: format!("c{}", self.rng.below(1000)),
                }
            }
            5 if !self.known_comments.is_empty() => {
                let id = self.rng.pick(&self.known_comments).clone();
                if self.rng.chance(1, 3) {
                    MutationSpec::DeleteComment { id }
                } else {
                    MutationSpec::EditComment {
                        id,
                        text: format!("c{}", self.rng.below(1000)),
                    }
                }
            }
            _ => {
                self.next_id += 1;
                let id = format!("e{}", self.next_id);
                self.known_entries.push(id.clone());
                MutationSpec::CreateEntry {
                    id,
                    text: "t".into(),
                }
            }
        }
    }
    pub fn step(&mut self) -> Result<(), String> {
        let Some(action) = self.choose() else {
            return Ok(());
        };
        self.apply_lenient(action)
    }
    /// Apply an action the RNG chose. Errors that mean "this action was not
    /// applicable right now" are swallowed: editing a record the client does not hold,
    /// deleting twice, subscribing twice. Every other error is a failure.
    fn apply_lenient(&mut self, action: Action) -> Result<(), String> {
        match self.apply(action.clone()) {
            Ok(()) => Ok(()),
            Err(e) if is_inapplicable(&e) => {
                self.trace.pop();
                Ok(())
            }
            Err(e) => Err(format!("{action:?}: {e}")),
        }
    }
    pub fn run(seed: u64, clients: usize, steps: usize) -> Result<(), Failure> {
        Sim::run_with(seed, clients, steps, true)
    }
    pub fn run_with(
        seed: u64,
        clients: usize,
        steps: usize,
        generate_direct: bool,
    ) -> Result<(), Failure> {
        let mut sim = Sim::new(seed, clients);
        sim.generate_direct = generate_direct;
        for i in 0..clients {
            sim.apply(Action::Subscribe {
                client: i,
                channel: "a".into(),
            })
            .unwrap();
        }
        for step in 0..steps {
            if let Err(error) = sim.step().and_then(|()| sim.check()) {
                return Err(Failure {
                    seed,
                    step,
                    error,
                    trace: sim.trace.clone(),
                });
            }
        }
        Ok(())
    }
}

fn is_inapplicable(e: &str) -> bool {
    // Read the client's error strings in crates/client/src/lib.rs and list the ones
    // that mean the action made no sense for the current state.
    ["update row missing"].iter().any(|s| e.contains(s))
}
