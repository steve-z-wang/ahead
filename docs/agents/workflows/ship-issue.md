# Workflow: ship an issue

Take a GitHub issue from assignment to a merged pull request. The steps below sequence skills from the [skills index](../skills.md); read each skill's instructions when you reach its step. The issue is the single record of state: anything decided or changed in a session that another person or agent would need to know must be written back to the issue.

## Labels used

| Label | Meaning |
|---|---|
| `in progress` | Someone is actively working on the issue. |
| `in review` | A pull request is open and waiting for review. |
| `decision` | Behavior or scope must be decided before implementation. The workflow cannot pass the design step while this label is present. |

Type, priority and area labels are set at triage and are not changed by this workflow.

## Steps

### 1. Claim the issue

- Read the issue and every comment. If it carries `decision`, note which decisions are still open.
- Add the `in progress` label.
- Comment `[start]` with the branch and worktree names.

```sh
gh issue edit N --add-label "in progress"
gh issue comment N --body "[start] branch codex/<name>, worktree .worktrees/<name>"
```

### 2. Isolate the work

Follow [using-git-worktrees](../skills.md#git-workflow). Create `.worktrees/<name>` on branch `codex/<name>` from `main`. Set up test prerequisites per [running tests](../../engineering/testing/running.md).

### 3. Choose the path by issue type

- Issue carries `bug`: follow step 3b, then continue at step 6.
- Otherwise: follow steps 3a, 4 and 5.

### 3a. Confirm the design

Follow [brainstorming](../skills.md#design-and-planning).

- Read the relevant [architecture](../../engineering/architecture.md) and [guarantees](../../engineering/guarantees.md) first.
- If the change touches a public API, sketch the exact surface and get an explicit OK before writing code.
- Comment `[design]` with the agreed approach. For an issue carrying `decision`, state each decision and its rationale, then remove the label.

```sh
gh issue comment N --body "[design] ..."
gh issue edit N --remove-label decision
```

### 3b. Reproduce and diagnose

Follow [systematic-debugging](../skills.md#development-and-debugging).

- Write a failing test that reproduces the reported behavior before changing any code. Comment `[repro]` with the test name and the observed failure.
- Find the root cause. Comment `[cause]` with the cause and the intended fix. If the cause is a design gap rather than a defect, stop and treat the issue as a feature: swap `bug` for `enhancement` and go back to step 3a.
- Fix it, then confirm the reproducing test passes and no other test changed.

```sh
gh issue comment N --body "[repro] test <name> fails with ..."
gh issue comment N --body "[cause] ..."
```

No plan file is needed for a bug. Write `[change]`, `[blocked]` and `[scope]` comments as in step 5 when they apply.

### 4. Plan

Follow [writing-plans](../skills.md#design-and-planning). Keep the plan under `docs/superpowers/plans/`; do not paste it into the issue. Comment `[plan]` with a link to the plan file on the branch.

### 5. Implement

Follow [executing-plans](https://github.com/obra/superpowers/tree/main/skills/executing-plans) or [subagent-driven-development](https://github.com/obra/superpowers/tree/main/skills/subagent-driven-development), with [test-driven-development](../skills.md#testing-and-verification) for each behavior change. Apply [rust-best-practices](../skills.md#development-and-debugging) where relevant.

Write back to the issue when any of these happen:

- `[change]` the approach changes from what `[design]` or `[cause]` said. Append a new comment; do not edit the old one.
- `[blocked]` progress stops on something outside the issue. Say what, and whether a new issue was opened.
- `[scope]` the work grows beyond the issue. Split the remainder into a new issue and link it.

Do not write debugging detail or failed attempts to the issue; they belong in commit messages and the pull request.

### 6. Verify

Follow [verification-before-completion](../skills.md#testing-and-verification). Run the suites the [testing strategy](../../engineering/testing/strategy.md) requires for the touched areas. Update affected documentation per the [writing conventions](../../writing/README.md).

### 7. Open the pull request

Follow [finishing-a-development-branch](https://github.com/obra/superpowers/tree/main/skills/finishing-a-development-branch) and [requesting-code-review](../skills.md#code-review).

- The pull request body includes `Closes #N`, the evidence from step 6, and any material limits.
- Swap `in progress` for `in review` and comment `[pr]` with the link.

```sh
gh issue edit N --remove-label "in progress" --add-label "in review"
gh issue comment N --body "[pr] <url>"
```

Handle review feedback per [receiving-code-review](../skills.md#code-review). A design change during review still gets a `[change]` comment on the issue.

### 8. Close out

After merge:

- Confirm the issue closed automatically; if not, close it with a comment.
- Remove the `in review` label if it is still present.
- Delete the worktree and branch.

```sh
git worktree remove .worktrees/<name>
git branch -d codex/<name>
```

## Pausing

If work stops before step 8, comment `[paused]` with the step reached and the next action, remove `in progress`, and keep the worktree. Whoever resumes starts from that comment.

```sh
gh issue comment N --body "[paused] at step 5; next: ..."
gh issue edit N --remove-label "in progress"
```
