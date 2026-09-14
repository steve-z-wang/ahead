//! Minimize a failing trace by deleting actions one at a time while the failure
//! reproduces. Plain delta debugging; a few hundred replays at most.
use crate::{Action, Sim};

pub fn replay(seed: u64, clients: usize, trace: &[Action]) -> Result<(), String> {
    // Removing one candidate action (in particular a `Restart`) can leave a later
    // action in the trace targeting a client that is still crashed; `Sim::client`
    // panics rather than returning an `Err` for that ("client is crashed"), since
    // ordinary forward stepping never produces such a trace. A shrink candidate is
    // free to be invalid in this way - it just must not be accepted as a smaller
    // reproduction of the *original* failure - so treat a panic here the same as any
    // other error whose `key` does not match: caught, reported under a key of its
    // own, and therefore always rejected as a shrink.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut sim = Sim::new(seed, clients);
        for a in trace {
            sim.apply(a.clone())?;
            sim.check()?;
        }
        Ok(())
    }));
    result.unwrap_or_else(|_| Err("shrink candidate panicked".to_string()))
}

/// The identity of a failure, so `shrink` can tell "the same failure" apart from a
/// different one that also happens to make `replay` return `Err`. `invariants::check`
/// formats an invariant failure as `"{name}: {detail}"` (joining several with `\n` if
/// more than one fires); every other error - a client/parse error from `apply` - has
/// no such prefix. Either way, the text before the first `": "` on the first line is
/// stable across trace edits that do not change *why* it failed: the invariant name
/// for an invariant failure, or the whole message (unchanged) for anything else.
pub fn key(error: &str) -> &str {
    let first_line = error.lines().next().unwrap_or(error);
    first_line.split_once(": ").map_or(first_line, |(k, _)| k)
}

pub fn shrink(seed: u64, clients: usize, mut trace: Vec<Action>) -> Vec<Action> {
    let Err(original) = replay(seed, clients, &trace) else {
        return trace;
    };
    let original_key = key(&original).to_string();
    loop {
        let mut removed = false;
        let mut i = trace.len();
        while i > 0 {
            i -= 1;
            let mut candidate = trace.clone();
            candidate.remove(i);
            if let Err(e) = replay(seed, clients, &candidate)
                && key(&e) == original_key
            {
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
        // only swallows it for the random runner). Its message has no "name: detail"
        // shape, so `key` is the whole message - see
        // shrink_of_the_issue_33_repro_keeps_the_same_failure for the other shape,
        // an invariant failure, where `key` is just the invariant's name.
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
    /// truth image, orphaning the row (no claim, no pending mutation) once the batch
    /// settles - which `record_rows_have_a_claim` catches.
    ///
    /// `shrink` is only allowed to accept a candidate removal when it fails with the
    /// same `key` as the original error (an invariant name, here
    /// "record rows have a claim"), so it cannot wander off to the shorter but
    /// unrelated "update row missing" failure that a lone `Direct` on a never-created
    /// row produces - that failure has a different key.
    ///
    /// It turns out `Subscribe` and `RejectNext` are not needed to reach this same
    /// invariant violation, though: `shrink` reduces this trace to `Enqueue, Freeze,
    /// Direct, Deliver, Deliver` (push then ack, no rejection, no subscription at
    /// all) and that still fails with the identical "record rows have a claim" key -
    /// a genuinely more minimal reproduction than task-10-report.md's, since a
    /// pending mutation's operation record apparently disappears from
    /// `otter_mutation_operation` the moment a `Direct` write lands on it, whether or
    /// not the original create is later accepted or rejected. `key` matching
    /// correctly keeps this reduction (it is the same invariant, not a different
    /// bug), it just cannot single out one specific *mechanism* by which that
    /// invariant fires - see task-11-report.md for the fix-round writeup.
    ///
    /// When issue #33 is fixed this trace no longer fails; rewrite the test around a
    /// different guaranteed failure (for example a `Direct` on a crashed client via a
    /// strict replay).
    #[test]
    fn shrink_of_the_issue_33_repro_keeps_the_same_failure() {
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
        let original_len = failing.len();
        let err = replay(1, 1, &failing).unwrap_err();
        assert_eq!(key(&err), "record rows have a claim", "{err}");

        let minimal = shrink(1, 1, failing);
        let err = replay(1, 1, &minimal).unwrap_err();
        assert_eq!(
            key(&err),
            "record rows have a claim",
            "minimal trace {minimal:?} failed with a different error: {err}"
        );
        assert!(
            minimal.iter().any(|a| matches!(a, Action::Direct { .. })),
            "minimal trace dropped the Direct write: {minimal:?}"
        );
        assert!(
            minimal.len() <= original_len,
            "minimal trace grew: {minimal:?}"
        );
    }
}
