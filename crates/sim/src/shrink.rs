//! Minimize a failing trace by deleting actions one at a time while the failure
//! reproduces. Plain delta debugging; a few hundred replays at most.
use crate::{Action, Sim};

pub fn replay(seed: u64, clients: usize, trace: &[Action]) -> Result<(), String> {
    let mut sim = Sim::new(seed, clients);
    for a in trace {
        sim.apply(a.clone())?;
        sim.check()?;
    }
    Ok(())
}

pub fn shrink(seed: u64, clients: usize, mut trace: Vec<Action>) -> Vec<Action> {
    if replay(seed, clients, &trace).is_ok() {
        return trace;
    }
    loop {
        let mut removed = false;
        let mut i = trace.len();
        while i > 0 {
            i -= 1;
            let mut candidate = trace.clone();
            candidate.remove(i);
            if replay(seed, clients, &candidate).is_err() {
                trace = candidate;
                removed = true;
            }
        }
        if !removed {
            return trace;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MutationSpec;

    #[test]
    fn shrink_removes_actions_that_do_not_matter() {
        // A trace that cannot fail: shrink returns it unchanged.
        let ok = vec![Action::Enqueue {
            client: 0,
            mutation: MutationSpec::CreateEntry {
                id: "e1".into(),
                text: "x".into(),
            },
        }];
        assert_eq!(shrink(1, 1, ok.clone()), ok);

        // A guaranteed failure: Restart on a client index that does not exist panics,
        // so instead use an action the sim reports as an error rather than panicking.
        // Enqueue of an Edit on a record no client holds is one: `apply()` reports it
        // as an error (this is not lenient stepping - `is_inapplicable` in step.rs
        // only swallows it for the random runner).
        let failing = vec![
            Action::Enqueue {
                client: 0,
                mutation: MutationSpec::CreateEntry {
                    id: "e1".into(),
                    text: "x".into(),
                },
            },
            Action::Freeze { client: 0 },
            Action::Enqueue {
                client: 0,
                mutation: MutationSpec::Edit {
                    id: "zzz".into(),
                    text: "y".into(),
                },
            },
        ];
        assert!(replay(1, 1, &failing).is_err());
        let minimal = shrink(1, 1, failing);
        assert_eq!(minimal.len(), 1);
        assert!(matches!(
            minimal[0],
            Action::Enqueue {
                mutation: MutationSpec::Edit { .. },
                ..
            }
        ));
    }

    /// A strict replay of the issue #33 repro from task-10-report.md: a Direct write
    /// on a still-dirty (unconfirmed pending-create) row gets baked into the client's
    /// truth image, so the create's later rejection restores the direct write as if
    /// server-confirmed, orphaning the row (no claim, no pending mutation) - which
    /// `record_rows_have_a_claim` catches once the rejection receipt lands.
    ///
    /// `shrink` does not converge on this trace's *Direct + RejectNext* pair, though:
    /// `replay`/`shrink` only ask "does it still fail," not "does it fail for the same
    /// reason." Deleting the CreateEntry (and everything after it except Direct) also
    /// makes replay fail, just for an unrelated, earlier reason - `Direct` targeting a
    /// row that was never created errors immediately in `apply()` with "update row
    /// missing" (the same precondition `is_inapplicable` swallows during random
    /// stepping). That one-action trace is shorter, so plain delta debugging - which
    /// has no notion of failure identity - happily keeps it. This is expected of the
    /// algorithm as specified (see task-11-report.md): it minimizes "a failure," not
    /// "this failure."
    #[test]
    fn shrink_of_the_issue_33_repro_finds_a_shorter_unrelated_failure() {
        let failing = vec![
            Action::Subscribe {
                client: 0,
                channel: "a".into(),
            },
            Action::Enqueue {
                client: 0,
                mutation: MutationSpec::CreateEntry {
                    id: "e1".into(),
                    text: "orig".into(),
                },
            },
            Action::Freeze { client: 0 },
            Action::Direct {
                client: 0,
                key: "Entry:e1".into(),
                text: "direct".into(),
            },
            Action::RejectNext {
                code: "sim.denied".into(),
            },
            Action::Deliver,
            Action::Deliver,
        ];
        let err = replay(1, 1, &failing).unwrap_err();
        assert!(err.contains("record rows have a claim"), "{err}");
        let minimal = shrink(1, 1, failing);
        assert_eq!(
            minimal,
            vec![Action::Direct {
                client: 0,
                key: "Entry:e1".into(),
                text: "direct".into(),
            }]
        );
        let err = replay(1, 1, &minimal).unwrap_err();
        assert!(err.contains("update row missing"), "{err}");
    }
}
