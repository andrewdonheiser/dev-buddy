# Fullsend Evaluation — Findings & History

**Purpose:** evaluate Fullsend (https://fullsend.sh/), an agentic SDLC platform, by running
its full triage → code → review → fix loop end-to-end on this repository, using GLM 5.3 at
high effort via the EnMaaS inference gateway.

**Evaluation window:** 2026-11-11 ~16:00 UTC → ongoing (document last updated 2026-11-13
~15:00 UTC; the core loop evaluation completed ~17:30 on day 2, follow-on observations
continue — see timeline and recommendation 7)
**Fullsend version:** v0.55.0 · per-repo install mode · `pi` runtime
**Status at time of writing:** core evaluation complete (PR #3 merged after the loop
self-terminated at its iteration cap); follow-on phases: CI added and green (PR #11),
auto-promoted PRs #9/#10, workflows-permission case study (F13). **Defaults deliberately
left on for continued observation** — see recommendation 7.

---

## TL;DR — issues found

**High severity**

- **The review↔fix loop doesn't converge on its own** (F1). Findings count stays flat
  (~14) while severity asymptotes to lows; the iteration cap (5 bot rounds) is the only
  terminator, and it fired. Sharper edge found later: **`/fs-fix` instructions are
  per-run** — a scoped instruction ("don't fix lows") is followed exactly by its run,
  but the next bot-triggered round starts with the default "fix everything" mandate and
  no memory of it.
- **Scoped instructions race a bot round the human cannot see coming** (F14): the first
  fix after a review verdict is bot-triggered within ~a minute — before a human can
  even read the review. A late instruction doesn't just fail to apply, it collides
  retroactively: the next run "complied" by reverting fixes the earlier un-instructed
  round had already made.
- **Setup failures are silent** (F2): harness defaults resolve to an unconfigured
  provider; nothing warns until runs fail confusingly.
- **No CI + Linux-only sandboxes = agents iterate blind** (F8/F11): the PR #3 head
  never compiled, through six fix rounds; nothing in the loop could run `swift build`.
  Remedied mid-evaluation: after CI went live, agent fix reports began referencing CI
  status as ground truth within ~90 minutes. **But red CI fuels the loop instead of
  stopping it** (F15): the fix agent still can't run Swift, so it responds to red CI
  with blind "fixes" that the next CI run falsifies — CI gates the human's merge, not
  the loop's ignition.

**Medium severity**

- **Failed pushes destroy the agent's work product** (F6) — ephemeral runner, no
  salvage. Compound case (F13): the code agent burned a full 7-minute run on a
  `.github/workflows/` push its app can never make (both triage's warning and its own
  "any path" instruction notwithstanding), then lost everything on rejection.
- **Default-on autonomy chains** (F12): triaged `bug`/`documentation`/`performance`
  issues auto-promote to the code agent; retro runs on every merge. Three unrequested
  agent runs observed in one evening.
- **`blocked` labels never expire on their own** (F16): triage correctly blocked
  issue #4 on PR #3; the PR merged 19 hours later and the issue sat labeled `blocked`
  — fully specified, ready to build — until a human happened to re-triage. The
  automation is all ignition, no resumption: everything starts without you, but
  nothing resumes when a blocker clears.
- **Review output is fragmented and easy to miss** (F17): each CHANGES_REQUESTED
  verdict is a ~120-character review stub with findings scattered as inline diff
  comments; only round 1 got a readable summary. Prominent fix-agent reports answer
  reviews the human has to hunt for — the loop's driver is its least legible
  artifact, while the agents get a structured, parseable findings channel.
- Scaffold-branch config doesn't reliably survive into `main` (F3); missing GitHub App
  installation is a silent no-op (F4); rulesets targeting more than the default branch
  block agent pushes entirely (F5).

**Low / informational**

- `/fs-fix` with a leading space silently no-ops (F7); phantom queued run (F9); every
  bot comment spawns a skipped workflow run (F10).

**What worked well**

- Scoped `/fs-fix` instructions are followed precisely, within their run.
- Triage: cheap ($0.07–0.12), verifies claims against the code, decomposes collectors
  into single-purpose issues, corrects errors in the human's filed text.
- Retro: from workflow data alone, independently reconstructed the PR #3 saga and filed
  the exact CI remedy this document's F8/F11 prescribe.
- The iteration cap, `/fs-fix-stop`, and the security boundaries (workflows permission,
  rulesets) all worked exactly as documented.

**Bottom line:** a capable but default-agentic pipeline. The agents are good; the
defaults assume more autonomy and more convergence than a solo repo wants. The tuning
recipe is in recommendation 7; the playbook for living with defaults is recommendation 1.

---

## 1. Environment

| Component | Value |
|---|---|
| Repository | `andrewdonheiser/dev-buddy` (Swift 6 / macOS SwiftPM app) |
| Mode | per-repo (`fullsend github setup --runtime pi`), not org manifest |
| Inference gateway | `https://api.enmaas.devshift.net` (EnMaaS), `auth: api-key`, API `openai-completions` |
| Model | `gateway/rits/zai-org/glm-5-3`, `effort: high`, for all six agents + sub-agents |
| Gateway key | repo secret `FULLSEND_INFERENCE_GATEWAY_API_KEY` |
| Roles enabled | triage, coder, review, fix, retro, prioritize |
| GitHub Apps installed | fullsend-ai-triage, -coder (also serves fix), -review, -retro, -prioritize |
| Branch protection | ruleset `rule1` on default branch: require PR, no deletion, no non-fast-forward |
| CI | none (relevant — see finding F8) |

Config on `main`: `.fullsend/config.yaml` — gateway block plus explicit per-agent model
overrides (`agents:` list). The overrides are **required**; see finding F2.

---

## 2. Timeline

All times UTC. Run IDs and SHAs are given as evidence pointers.

### Day 1 — 2026-11-11: setup and first full cycle

| Time | Event |
|---|---|
| ~16:00 | `fullsend github setup` creates scaffold PR #1; merged. CLI installed at `~/.local/bin/fullsend` (v0.55.0, checksum-verified). Required adding `workflow` scope to the GitHub PAT first. |
| 16:32 | First triage run **fails**: `Vertex inference requires FULLSEND_GCP_PROJECT_ID…`. Root cause: the triage harness pins `model: opus`; the `agents:` override block was missing from `main` (it was pushed to the scaffold branch but did not survive into the merge — see F3). `opus` on the `pi` runtime resolves to Claude on Vertex. |
| ~17:00 | User re-applies the `agents:` override block to `.fullsend/config.yaml` via GitHub web UI (commit `c568adc`). |
| 16:52–17:15 | Re-triggered triage runs complete **green but do nothing** — silent no-op. Logs show `collaborator permission lookup failed for fullsend-ai-triage[bot]`. Root cause: the five fullsend GitHub Apps were not installed on the repo (F4). |
| ~17:20 | User installs all five apps, scoped to this repo. |
| 16:52 (apps installed after) | **Triage succeeds** on issue #2 ("add the ablility to have a terminal console in a tab"): categorized as feature request, read the codebase (`DocumentStore`, `TabSidebarView`, `OpenDocument`), weighed SwiftTerm vs. hand-rolled PTY, proposed test cases. |
| 17:20 | User comments `/fs-code`. |
| 17:21–~17:50 | Code agent runs (~30 min) and opens **PR #3** "Add terminal tabs running the user's shell in a tab" (commit `c6b9942`). PR admits `swift test` could not be run in the sandbox. |
| 18:14 | **Review round 1**: CHANGES_REQUESTED — 14 findings (1 high, 4 medium, 9 low). The high finding is a real logic bug: ⌘]/⌘[ tab cycling permanently broken; the PR's own new test fails at an assertion, proving the suite was never run. Reviewer also noticed this exact feature was previously committed and reverted (`bfd6f04` → `d6972c7`) from git history. |
| 18:20 | User comments `/fs-fix`. |
| 18:40 | Fix agent pushes `8355576` — 12 of 14 findings resolved (high bug fixed, layering fixed, tests made isolated). |
| 19:14 | **Review round 2**: CHANGES_REQUESTED — ~14 findings (2–3 medium roots: `closeAll()` kills terminals without confirmation via saved-view path; `TerminalSession` reaches into `DocumentStore.shared`). Review now cites `AGENTS.md` (added to `main` earlier — commit `8799741`). |
| 19:15 | **Fix round 2 starts automatically** — triggered by `pull_request_review` (the CHANGES_REQUESTED verdict itself). Auto-fix on changes-requested is default behavior. |
| 19:23 | User creates branch-protection ruleset `rule1` targeting **all branches**. |
| 19:35 | Fix round 2's agent work **completes cleanly, but the push is rejected**: `GH013: Repository rule violations… Changes must be made through a pull request` on `agent/2-terminal-tab`. The `--force-with-lease` retry also rejected. **All fix work lost** (sandbox discarded). Failure surfaced only as a post-script failure comment (F6). |
| ~19:40 | User re-scopes `rule1` to the default branch only. |
| 20:16 | User comments `" /fs-fix"` — **silently skipped** because of the leading space (F7). |
| 20:20 | User comments `/fs-fix` (clean). Run 43095470483 is accepted but **never creates a single job** — a GitHub Actions phantom/zombie run stuck in `queued` for 12+ hours (F9). Cancel endpoint reports "Cannot cancel a workflow run that is completed"; DELETE returns 403. Harmless but unremovable without GitHub Support. |

### Day 2 — 2026-11-12: recovery and the auto-iterate loop

| Time | Event |
|---|---|
| 12:31 | User comments `/fs-fix` (fresh run; the zombie is simply abandoned). |
| 12:44 | Fix agent pushes `b99f86c` — redo of the lost round-2 fixes; push succeeds now that the ruleset is scoped to `main`. |
| 13:16 | **Review round 3**: CHANGES_REQUESTED. |
| 13:31 | **Auto-fix 3** (triggered by the review verdict) pushes `c81f271`. |
| 14:07 | **Review round 4**: CHANGES_REQUESTED. |
| 14:29 | **Auto-fix 4** pushes `578eb3b`. |
| 15:15 | **Review round 5**: CHANGES_REQUESTED — **1 medium + ~16 low**, plus a few carried findings. The medium is an API-shape nit (`selectedTerminalID` publicly settable). Substantive carried finding: SwiftTerm delivers exec failures via `processTerminated` (exit 127), not `processFailedToStart`, so the failure overlay never renders for a missing shell. |
| 15:15 | **Auto-fix 5 starts.** Human then stops the exercise: loop judged non-converging (F1). |
| 15:35 | Auto-fix 5 pushes `3332755`; review round 6 starts automatically. The loop continued unattended. |
| ~16:00 | Human checks out the PR branch locally (`3332755`) and runs `swift build`: **the PR code does not compile** (F11). Fixed locally with a one-line patch; `swift build` then completes in ~7 s. |
| 16:05 | Human posts a scoped `/fs-fix` instruction containing the exact compiler error, root cause, and prescribed fix. |
| 16:10 | Fix round 6 (human-directed) pushes `b7bdd56` in **~5 minutes** — the exact prescribed two-line change, nothing else. Verified locally: `swift build` clean, `swift test` **51/51 across 7 suites**, including the tab-cycling test that failed in round 1 and the close-confirmation coverage round 2 flagged as missing. |
| 16:54 | **Review round 7**: CHANGES_REQUESTED — **0 high, 0 medium**, 7 low + 2 info (both reclassified *down* by the reviewer because authorization was already recorded in AGENTS.md/TASKS.md). |
| 16:55 | **Iteration cap fires as designed.** The round-7 verdict auto-triggered fix iteration 7; the pre-script counted 6 prior fix commits, exceeded the bot cap of 5, and the run failed *before the sandbox started*: "Fix iteration 7 exceeds bot cap of 5. Escalating to human… A human can still direct the agent with /fs-fix (up to 10 total iterations)." `needs-human` label applied. Zero cost — the run's own health check: "run never reached an iteration." **Loop terminated by design.** |
| ~17:15 | **Human merges PR #3.** |
| 17:17 | **Retro agent fires automatically on the merge** — the final pipeline stage, analyzing the full workflow. |
| 17:21 | Human files issue #5: collector for the 7 remaining low-severity findings from round 7. Filing it triggers triage, which verifies every item against the merged code, corrects a wrong file path in the filed text, and **decomposes #5 into two single-purpose issues** (#6: the exit-127 behavioral fix; #7: the tests/polish batch), closing #5 as split. |
| 17:33 | **Auto-code promotion discovered (F12):** triage on #6 labeled it `bug` + `ready-to-code`, and the **code agent started automatically** — no `/fs-code` command was issued. The default `TRIAGE_AUTO_CODE` categories (bug, documentation, performance) promote straight to coding. |
| 17:40 | **Retro completes** (success, ~23 min) and files **issue #8: "Add macOS CI running swift build and swift test on PRs"** — independently reaching the same conclusion as findings F8/F11 here, from the workflow data alone. See agent-quality observations. |
| 19:41 | Human, applying recommendation #1's playbook, posts a **scoped** `/fs-fix do not fix any low issues` on PR #9 (the auto-coded fix for issue #6). Fix iteration 4 complies exactly; review round 4 (19:56) returns CHANGES_REQUESTED with **zero high/medium findings — lows only**. |
| 19:43 | Human merges **PR #10** (issue #7 polish batch). Verified locally afterward: `swift build` clean on `main`; `swift test` unverified (no CI exists yet). |
| 19:44 | Human runs `/fs-code` on **issue #8** (the CI proposal). The code agent completes ~7 min of correct work, then the **push is rejected: the coder app lacks `workflows` write permission** (F13). The entire work product is lost with the ephemeral runner. |
| 19:58 | A second `/fs-code` (posted on issue #6, where PR #9 already exists) runs and correctly produces **no PR** — "agent determined no changes needed." No duplicate branch was created. |
| 20:04 | Human pushes `ci.yaml` by hand (the file the agent could not push, F13) plus this findings document, as **PR #11** — via PR because the repo's own ruleset correctly blocks direct pushes to `main`. |
| 20:15 | **First CI run ever — fails.** SwiftTerm 1.99.3 requires `swift-tools-version: 6.2`; the runner image's default Xcode was older. Diagnosed from the failure log and fixed in two minutes (macos-26 image, select newest Xcode) — versus PR #3's uncompilable code surviving six fix iterations because nothing could check it. The fix for F8/F11 failed safely on its first run and was corrected immediately: the argument for CI, demonstrated by CI. |
| 20:17 | **CI green: 135/135 tests** across 17 suites (test count up from 51 at PR #3 — the auto-coded PRs #9/#10 added ~84 tests). First machine-verified `swift test` in the repo's history. |
| 20:43 | Review agent reviews **PR #11** (its first review with CI available): CHANGES_REQUESTED — one legitimate medium (no `permissions:` block on the CI workflow; least-privilege), plus process nits including correctly flagging that CI + findings-doc in one PR violates the repo's own one-feature convention. No fix loop starts: the fix bot cannot push to branches touching `.github/` (same F13 wall). |
| 21:04 | **Human merges PR #11.** Issue #8 auto-closes. First CI run on `main` itself starts. **Retro agent auto-fires on the merge** — the third autonomous edge firing of the evening (auto-code #6, auto-code #7, auto-retro), observed and priced (~$0.15, ~25 min). |
| 21:10 | Human opens **PR #12** (two-line least-privilege `permissions:` fix from the review). **Evaluation decision recorded:** the pipeline-tuning configuration worked out this evening (see recommendation 7) is deliberately **not applied** — the evaluation is of fullsend's defaults, and disabling default behaviors mid-evaluation would contaminate it. Every subsequent autonomous firing is data, not noise. |
| ~21:30 | Human posts `/fs-fix merge main into this branch and resolve the conflicts…` on PR #9 (the conflict from PR #10). The fix agent merges `main` (`a76376c`, carrying PRs #10 and #11) and resolves the test-file conflict, preserving both sides. **PR #9 conflict resolved.** |
| 21:41 | The merge commit auto-triggers review round 5 on PR #9: CHANGES_REQUESTED, 5 lows (the same carried ones). The push also triggers the **first CI run on a PR branch** — green. |
| ~22:00 | **Instruction-scope discovery (F1 extension):** the review verdict auto-triggers fix iteration 5 (**bot-triggered, no instruction**), which "Addressed all 5 open findings" — all lows — directly contradicting the human's 19:41 "do not fix any low issues" instruction. That instruction was obeyed exactly by its own run (iteration 4 made no changes and filed the lows under "Disagreed"), but **`/fs-fix` instructions are per-run**: the next bot-triggered round starts fresh with the default "fix everything flagged" mandate. Only the code persists across rounds, not the guidance. |
| 22:11 | Review round 6 on PR #9: CHANGES_REQUESTED again. Loop active. Notably, iteration 5's report references CI: *"the macOS CI job (build-and-test) is green on the prior head and will re-verify this commit on push"* — **the first agent report in the evaluation to treat CI as ground truth**, ~90 minutes after CI went live. The retro's central validation criterion is met (see agent-quality observations). |

Alongside: issue #4 ("support pr review workflow") was filed and triaged successfully
during day 1 evening — confirms different issues run independently/in parallel.

---

### Day 3 — 2026-11-13: PR #14 and the instruction race

| Time (UTC) | Event |
|---|---|
| 22:57 (day 2) | Human merges **PR #9**; issue #6 auto-closes. Retro auto-fires on the merge (observation #3). |
| 22:58 (day 2) | Human merges **PR #12** (CI permissions fix). Retro auto-fires again (observation #4) — its write-up correctly reconstructs the whole chain: human-authored PR implementing the review's medium finding, itself needed because the coder app can't push workflow files (F13). |
| morning | Issue #4 re-triaged: `blocked` dropped (both prerequisites — PR #3 and #2 — had been satisfied since day 2, ~19 hours earlier; nothing re-fires triage when a blocker closes, so the label was stale until the human prompted — **F16**). Labeled `triaged`. Human runs `/fs-code`. |
| ~13:08 | **Coder opens PR #14**: the PR-review workflow with worktree-backed work units (~1,341 lines, additive, well-structured per the risk assessment). First CI run: **failure**. |
| 13:36 | Review round 1: CHANGES_REQUESTED — 16 findings (1 high: cross-store selection desync; 5 mediums; 10 lows). |
| 13:37 | **Fix iteration 1 fires (bot-triggered) — 60 seconds after the review verdict.** No instruction exists yet; default mandate applies. |
| 13:58 | Iteration 1 completes (~21 min): "Addressed all 16 review findings and the failing project CI job with one commit" — including all ten lows. CI on the new commit: **failure** again. |
| 14:01 | Human, having read the review, posts `/fs-fix do not fix low priority or nits` — **25 minutes after the bot round started, 3 minutes after it finished.** **F14: the instruction was structurally late.** |
| 14:02 | Fix iteration 2 (human-triggered) starts. |
| 14:17 | Iteration 2 completes — **complies with the instruction by reverting the low/nit fixes iteration 1 had already applied**, keeping the high and medium fixes. Also claims to fix the CI failure ("fixture closure captured self before initialization"). CI on the new commit: **failure again** — 4 behavioral test failures in `WorkUnitStoreTests` (worktree paths never created on the runner), a different cause than the compile error claimed fixed. **F15: red CI the agent cannot reproduce is loop fuel.** |
| 14:19 | Review round starts on the new head. Loop active; CI red on all three commits. |

---

## 3. Findings

Severity here reflects impact on the evaluation, not fullsend's own severity scale.

### Product / platform findings

(Numbered by discovery order; F11 was found on day 2 during local build verification,
F12 at wrap-up when triage auto-promoted issue #6 to code, F13 from the workflows-
permission push rejection on the `/fs-code` run against issue #8, F14/F15 on day 3
from the PR #14 fix loop — the instruction race and red-CI churn respectively — F16
from issue #4's stale `blocked` label, and F17 from reading PR #14's review trail on
GitHub; the last three are day 3.)

**F1 — The review↔fix auto-loop does not converge on its own (high, partially by design).**
Once a review submits CHANGES_REQUESTED, fix runs automatically (default behavior for PRs
authored by the fullsend coder bot); every fix push triggers a fresh review. Each fix
round resolves most findings but writes new code, and the reviewer (at high effort)
reliably finds new low-severity findings in it. Observed: severity converges (high →
mediums → 1 medium), count does not (≈14 findings every round; round 5's lows were
mostly nitpicks on code fix-round-4 itself introduced).

**Extension (day 2, PR #9): `/fs-fix` instructions are per-run, not per-PR.** The human
posted a scoped instruction ("do not fix any low issues"); the human-triggered run it
accompanied obeyed it exactly — made no changes, filed both open lows under "Disagreed"
citing the instruction. Hours later the human posted a second instruction (merge-main to
resolve a conflict); that run obeyed *it*. But the conflict-resolution push triggered a
review, the verdict auto-triggered the next fix round **with no instruction**, and it
"Addressed all 5 open findings" — all lows — exactly what the earlier instruction had
forbidden. Each fix run is a fresh agent with only the review body plus *its own*
instruction; there is no memory of prior runs' mandates, and bot-triggered rounds carry
no instruction at all, so they default to "fix everything flagged." Consequence: command
discipline cannot shape the loop's trajectory — only `/fs-fix-stop`, the iteration cap,
or merging bounds it. (Corollary: any human guidance must be re-stated in every
human-triggered run, and nothing can reach bot-triggered runs at all.)

**Refinement (day 3, PR #14): agents can discover prior instructions in the PR comment
history and adopt them as standing guidance.** Fix iterations 4 and 5 (bot-triggered,
no instruction) both cited the human's earlier "do not fix low priority or nits"
comment as "the maintainer's standing instruction on this PR," and iteration 5 made no
changes on that basis. So the mandate channel is per-run, but the agent *can* choose to
read the comment history — here correctly, and to good effect: the instruction wasn't
wasted, it arrived too late for round 1 (F14) and took effect once an agent went
looking. Unreliable by design, though: nothing guarantees later runs will notice, read,
or follow prior instructions — the observed compliance was the model's initiative, not
a mechanism.

The loop is bounded, per the official Fix agent docs: **bot-triggered fixes are capped
at 5 per PR** (configurable — the runner default surfaced in the logs as
`ITERATION_CAP:-5`), human-triggered `/fs-fix` at 10 total shared across both trigger
types. Near the cap the agent applies the `needs-human` label; past the cap the run
fails with an escalation message before the sandbox starts. The exercise demonstrated
this end-to-end: the 7th iteration exceeded the bot cap, the run failed pre-sandbox at
zero cost, and the loop handed control back to the human with the `needs-human` label.
So the correct framing is not "infinite loop" but "up to N iterations of asymptotic
polish per PR, ~$2–3 and ~45–90 min each, by design" — where the human's stopping rule
should fire well before the cap, because the cap is a safety valve, not a convergence
guarantee: findings count stayed ≈14 across rounds while severity dropped to zero
highs/mediums only at round 7.

Documented mechanics relevant here: `/fs-fix-stop` adds the `fullsend-no-fix` label
(bot-triggered only; human `/fs-fix` still works); bare `/fs-fix` means "fix whatever
review flagged" (broadest mandate — the observed driver of churn), while
`/fs-fix <instruction>` scopes it; the fix agent reads only the review body and the
instruction — not PR comments, inline review comments, or CI logs; external URLs in
instructions are blocked by the sandbox proxy (paste content inline). Notably, three
of the six fix rounds were **auto-triggered by review verdicts**, not by any user
command — command discipline alone cannot stop those; only `/fs-fix-stop` (or merging)
ends them.

**F2 — Harness defaults silently resolve to an unconfigured provider (high).**
The stock harnesses pin `model: opus`; on `pi` that resolves to Claude on Vertex. Without
GCP credentials the run dies at credential setup. The fix (explicit `agents:` overrides
including `subagents.default`) is documented in fullsend's own org-manifest comments
("never a bare name") but is easy to miss in per-repo mode. Failure is loud here only
because Vertex credentials were absent; a configured-but-unintended provider would be
silent.

**F3 — Scaffold-branch config doesn't reliably survive into `main` (medium).**
The `agents:` override commit pushed to the scaffold branch during setup did not survive
the merge to `main` (possibly a setup re-run regenerated the branch). Symptom: F2 above.
Required manual re-application via the GitHub web UI.

**F4 — Missing GitHub App installation is a silent no-op (medium).**
With the fullsend apps not installed, dispatch runs complete **green** while doing nothing;
the only trace is a single log line (`collaborator permission lookup failed for
fullsend-ai-triage[bot]`). This cost a debugging round-trip. A setup-time validation or a
visible annotation would fix it.

**F5 — Ruleset interaction: fullsend pushes directly to PR branches (medium).**
The fix agent pushes commits to its own PR head branch. A ruleset targeting all branches
("changes must be made through a pull request") therefore rejects the bot's push — the
rule intended for `main` breaks the agent loop on feature branches. Not fullsend's bug,
but a real deployment footgun for anyone combining rulesets with fullsend.

**F6 — Failed pushes lose the agent's entire work product (medium).**
When the push was rejected (F5), the completed fix work existed only in the sandbox and
was discarded. No retry, no PR-based fallback, no artifact preservation. The failure was
at least surfaced as a post-fix failure comment with the full git error.

**F7 — Command parsing is brittle: a leading space silently no-ops `/fs-fix` (low).**
The workflow gates on `startsWith(comment.body, '/fs-')` with no trimming. `" /fs-fix"`
creates a skipped run and no feedback anywhere the user will see.

**F8 — Agents cannot run the project's tests; no CI gate existed (high, shared blame).**
The code agent shipped a PR whose own new test fails at an assertion — i.e., `swift test`
was never executed in the sandbox, and the PR said so. The review agent caught it, which
is good, but review is an expensive test runner. A `swift build`/`swift test` workflow on
`pull_request` would gate this at merge time and give the fix agent actionable failures.
(The fix agent also could not inspect CI: `gh pr checks` → 403 in its sandbox.)

**F11 — The PR shipped uncompilable code through three fix rounds (high).**
The strongest single data point of the evaluation. Local `swift build` on the PR head
(`3332755`, the output of fix round 5) failed:

```
TerminalSession.swift:133: error: type 'NSAccessibility.Notification' has no member 'announcement'
```

Chain of custody: review round 2 recommended posting the accessibility announcement
"from a real element" and prescribed `NSAccessibility.post(element:notification:userInfo:)`
with `.announcement` — an API that **does not exist on macOS** (it is iOS's
`UIAccessibility.Notification.announcement`; verified against the installed macOS SDK,
which has no such member on AppKit's `NSAccessibility.Notification`). Fix round 3
implemented the reviewer's suggestion verbatim; because nothing in the loop ever invokes
the compiler (F8), the error survived fix rounds 3, 4, and 5 and five review rounds —
including a review process that was actively checking the accessibility code for
correctness in every round. A one-line local patch (SwiftUI's
`AccessibilityNotification.Announcement(message).post()`, the correct macOS API) made the
package build in ~7 s.

Implications: (a) the reviewer's remediation suggestions are unverified and can be
platform-wrong; (b) the fix agent will faithfully implement a wrong suggestion;
(c) no amount of review iteration substitutes for a compile/test gate. Also of note:
the review agent that was running when this was discovered (round 6) would have needed
to catch a compile error without a compiler. A `swift build` CI check would have caught
this on the first push.

**F12 — Auto-code promotion is on by default (medium — behavior to be aware of).**
Filing an issue in a default auto-promotion category (`bug`, `documentation`,
`performance`) chains straight through to the code agent once triage marks it
`ready-to-code` — no `/fs-code` command. Discovered when triage on issue #6 (a `bug`)
auto-started the code agent ~5 minutes after the issue was created by an earlier triage
run. The chain is: issue filed → triage → code agent → PR → review → fix — fully
autonomous end to end. For a solo evaluation repo this was benign (the auto-coded issue
was a real, well-specified bug), but owners should know that a casually-filed `bug`
issue can trigger ~$2–3 of inference and a PR without any explicit request. The
`TRIAGE_AUTO_CODE` mode is configurable (`on`/`off`/`discretionary`) per the triage
harness.

**F13 — The code agent burns a full run on a push it cannot make, then loses the work
product (medium; design gap, not a security bug).**

*Case: `/fs-code` on issue #8 (the retro's CI proposal), 2026-11-12 19:44–19:52 UTC,
run 43293266561.*

Issue #8 asks for exactly one deliverable: a new file at
`.github/workflows/ci.yaml`. The code agent ran for ~7 minutes and did genuinely
competent work, all recoverable from the run log:

- Read the issue, confirmed no existing `agent/8-*` branch, verified the
  `.github/workflows/` gap against the repo
- Studied the repo's conventions: read `fullsend.yaml` and `prioritize.yml` for
  style, checked git history for commit format (correctly concluded "plain
  imperative, no conventional commits")
- **Wrote `.github/workflows/ci.yaml`** matching the issue spec exactly
  (`pull_request` + `push` to main, macOS runner, build + test)
- **Edited `AGENTS.md`**'s "Verify before you finish" section so future agents treat
  CI as the arbiter — the exact optional follow-on the issue proposed
- Added a `TASKS.md` entry per the repo's task-log convention
- Ran a secret scan, validated the YAML with PyYAML, attempted to download
  `actionlint` to lint the workflow (blocked by the sandbox network policy — a
  reasonable attempt), and explicitly disclosed "`swift` is not available in this
  Linux sandbox" per AGENTS.md's rules

Then the post-script's `git push` was rejected:

> ⚠️ **Post-code script failed** — Push rejected — workflows permission (exit code 1)
> **Security boundary:** the coder app intentionally lacks `workflows` write
> permission. Changes to `.github/workflows/` must be made outside the agent (e.g.,
> via a manual PR).

**What worked (and is not a bug):**

- The permission boundary itself is correct. GitHub treats workflow-file write access
  as arbitrary code execution on every future Actions run; an agent app holding it is
  a repo-takeover vector. Fullsend not granting it is the right design.
- The failure UX was good: a clear, actionable comment explaining the boundary, why
  it exists, and the workaround.

**What failed (the design gap):** the run was doomed before it started, and the
harness had two independent signals saying so — both of which were overridden:

1. **Triage flagged it.** The triage on issue #8 explicitly stated the change was
   under `.github/workflows/`, "which the automated code agent cannot create under
   current permissions." That warning appears in the run log, was read by the agent —
   and consumed by nothing downstream.
2. **The agent's own instructions contradicted the platform.** The agent reasoned, in
   its log: "the triage says the change is under `.github/workflows/` which the
   automated code agent cannot create under current permissions — but per my agent
   definition: 'You may propose changes to any path, including `.github/`' … So I can
   implement it." The instruction layer says "any path"; the permission layer says
   otherwise; the instruction layer won, and the run proceeded.

Compounding the loss: **the work product was discarded**. The runner workspace is
ephemeral, and when the push failed, the `ci.yaml`, `AGENTS.md` edit, and `TASKS.md`
entry vanished with it. The logs record tool-call summaries (`write:
.github/workflows/ci.yaml`) but not file contents, so nothing is recoverable. This is
finding F6 (failed pushes lose the agent's entire work product) recurring on top of
the permission boundary — the worst possible pairing, since this push had ~0% chance
of success from the first token of inference.

**Classification:** not a security bug and not a crash bug — a **design gap at the
seam between fullsend's own layers**: triage's non-binding warning, an agent
definition with an undocumented exception to "any path," and a push-failure path with
no salvage mechanism. Any of these would have converted the doomed run into a useful
one:

- a **pre-flight path check** refusing `.github/workflows/` targets before inference
  starts (cheapest; saves the whole run), or
- **salvage-to-comment**: on push failure, post the generated file contents to the
  issue so a human can copy them into a manual PR (the failure comment's own advice —
  "apply those changes via a manual PR" — implies this, but the content to apply was
  already deleted), or
- correcting the agent definition so "any path" doesn't include the one path the
  platform will always reject.

**Cost and blast radius:** one run, ~$0.10–0.15, unrecoverable. The concern is the
combination with F12: any future issue asking for a workflow change that triage
categorizes as `bug`/`documentation`/`performance` will auto-chain into the code agent
and hit the same wall, losing its work every time — a guaranteed recurring waste loop
with no human in the loop to break it. The remedy for this repo is the same as
F8/F11's: once the human adds `ci.yaml` manually (done locally after this finding,
2026-11-12), the class of "please change CI/workflows" requests has a concrete human
path and the agent path can simply be declined.

**F14 — Scoped instructions race a bot round the human cannot see coming (high).**

*Case: PR #14 (issue #4's implementation), 2026-11-13 13:36–14:17 UTC.*

The review posted its CHANGES_REQUESTED verdict (16 findings) at 13:36; the fix agent
fired at 13:37 — **60 seconds later**, bot-triggered, with the default "fix everything
flagged" mandate. The human read the review and posted the scoped instruction
(`/fs-fix do not fix low priority or nits`) at 14:01 — 25 minutes after the bot round
started, 3 minutes after it finished. The instruction was structurally late, and
**nothing told the human that**:

- No signal accompanies a review verdict that a fix round has already ignited. The
  only artifact is the fix agent's own status comment, which posts when the run
  starts — visible only if you're watching the PR in real time.
- The race is unwinnable by design: reading a 16-finding review takes longer than the
  ~1-minute window between verdict and bot-fix ignition. Any scoped instruction a
  human posts after *reading* the review arrives after round 1 has already run.

The late instruction didn't just fail to apply — it **collided retroactively**.
Iteration 2, obeying "do not fix lows," found that iteration 1 had already fixed them;
its way of complying was to *revert* the ten low/nit fixes in a new commit while
keeping the high and mediums. Net effect: two commits of churn re-litigating the same
findings, and a PR whose diff now contains fix-then-unfix of the same code. A
compliant instruction produced *more* churn than no instruction at all.

This compounds F1's per-run scope finding: not only do instructions fail to persist
across rounds, they cannot reach round 1 at all, and when they arrive late they can
invert prior rounds' work. **Consequence for the playbook (recommendation 1): scoped
instructions can shape rounds ≥2 only, and only if the human wins a race against a bot
that fires within the minute.** The reliable levers remain `/fs-fix-stop` (which does
pre-empt, since it gates ignition) and merging.

*Remedies fullsend could adopt:* post an igniting-fix notification on the review
verdict itself; hold bot-fix ignition for a configurable grace period after
CHANGES_REQUESTED (even 10 minutes would let a human scope the round); or let the
`/fs-fix` instruction attach to the PR (sticky scope) rather than the run.

**F15 — Red CI the sandbox cannot reproduce fuels the loop instead of stopping it
(high).**

*Case: PR #14, three commits, three red CI runs, 2026-11-13.*

This is the F8/F11 blindness recurring *with* CI present — and demonstrating that CI
alone doesn't close the loop. CI worked exactly as intended on PR #14: every push was
built and tested, and it caught a real problem the agent's reports would never have
surfaced — 4 behavioral test failures in `WorkUnitStoreTests` (worktree directories
never created on a clean runner), with precise signatures (named tests, exact
expectation failures, file:line).

But the fix agent's Linux sandbox still cannot run `swift build`/`swift test`, so it
responds to red CI **blind**: iteration 2's report claims "also fixed the pr-related
CI compile failure … (fixture closure captured self before initialization)" — a
plausible-sounding diagnosis the next CI run falsified (the failure was behavioral,
not a compile error, and persisted identically). The observed cycle:

> review sees red CI → CHANGES_REQUESTED → fix fires → agent cannot reproduce the
> failure → pushes a blind "fix" with a confident wrong diagnosis → CI red again →
> repeat

CI gates the **human's** merge decision but not the **loop's** ignition. Red CI — the
strongest possible signal that a human should look — instead becomes another finding
for the auto-fix loop to churn against, with each round spending real money
(~$0.10–0.15) on changes that cannot be verified by their author. Without
intervention the terminator is the same iteration cap as F1, ~5 rounds later.

*What would break the cycle:* red CI suppressing bot-fix ignition (routing the PR to
`needs-human` instead — the failure is, by definition, not fixable-blind); or a
sandbox that can run the project's tests (macOS runners for macOS projects, or
remote-verification against CI as part of the fix loop rather than after it). Absent
either, the practical rule for the human: **when CI is red on a bot PR, the next fix
round is guaranteed to be a guess — stop it (`/fs-fix-stop`) or diagnose it yourself.**

**F16 — `blocked` is a point-in-time snapshot; nothing re-triages when a blocker
resolves (medium).**

*Case: issue #4 ("support pr review workflow"), 2026-11-11 → 2026-11-13.*

Triage (day 1, 19:34 UTC) blocked issue #4 on the terminal foundation — PR #3 /
issue #2 — with a correct, well-reasoned dependency analysis, and over three triage
rounds answered every design question the issue raised (nested tab-tree reused from
the reverted `bfd6f04`, workspace functionality excluded, worktrees kept until
explicitly deleted). PR #3 merged day 2 at ~17:15; issue #2 closed. Issue #4 then sat
labeled `blocked` — fully specified, prerequisites satisfied — for **~19 hours**,
until the human happened to ask why it wasn't moving and re-ran `/fs-triage` (day 3
morning), which dropped the label and marked it `triaged`. The `/fs-code` run that
produced PR #14 followed within hours.

What failed: the dependency was recorded as a **label plus prose**, not a live link.
Triage's own comment even lists the blocking issues/PRs by URL — GitHub has the
identities — but nothing subscribes to their resolution. No scheduled sweep over
`blocked` issues, no event hook on blocker closure, no expiry.

Why it matters — the asymmetry: **fullsend's automation is all ignition, no
resumption.** Everything that can start without the human does (auto-code F12,
auto-fix F1, auto-retro on merge), but the one transition that requires remembering —
"the prerequisite landed; resume the blocked work" — is entirely on the human. In a
solo repo the stall is eventually noticed; in a team it is invisible indefinitely.
It inverts the product's promise: the pipeline moves issues forward automatically,
except when it silently doesn't.

*Cheap remedies:* a scheduled triage pass over `blocked` issues checking blocker
state; or wiring blocker closure (issue closed / PR merged) to a re-triage run —
the same event plumbing that already auto-fires retro on merges.

**F17 — Review output is fragmented and low-visibility; the loop's driver is its
least legible artifact (medium).**

*Case: PR #14, four review rounds, 2026-11-13.*

Each CHANGES_REQUESTED verdict is recorded as a formal GitHub review whose body is a
**~120-character stub**; the findings themselves are attached as **inline comments on
specific diff lines** (visible in the Files changed tab, or as collapsed "commented on
line N" blocks in the conversation timeline); and the machine-readable findings blob
rides in a hidden HTML comment (`<!-- fullsend:review-findings-v2:… -->`) that the fix
agent parses. Only **round 1** additionally posted a long-form "## Review / ###
Findings" summary comment — rounds 2–4 posted none.

Consequence: on the PR conversation, five prominent fix-agent reports ("### 🔧 Fix
agent — iteration N…") each answer reviews the human can barely find. The question
that drives every human decision in the loop — *what did the reviewer actually object
to?* — requires visiting Files changed and reading scattered inline annotations. The
asymmetry is the point: **agents get a structured, parseable channel (the findings
blob); humans get the scraps.** The review is the loop's ignition signal, its
severity ladder, and the de facto gate on merging — and it is the least visible
artifact the pipeline produces.

What fullsend gets right: inline line-anchored comments are the idiomatic GitHub
review mechanism — more actionable than a wall of prose — and the round-1 summary is
well-written (severity-grouped, file:line references).

*Remedies:* post the summary comment every round, not just the first, with a verdict
line and counts by severity; or carry the summary in the review body itself (GitHub
renders it in the timeline entry); or have each fix report link the review it
answers.

**F9 — Phantom queued run (low, GitHub-side).**
Run 43095470483 hung in `queued` with zero jobs for 12+ hours; cancel endpoint reported it
"completed", delete returned 403. GitHub infrastructure inconsistency, not fullsend's
fault, but the workaround (abandon and re-trigger) should be known.

**F10 — Benign noise: every bot comment spawns a skipped run (informational).**
Every comment any fullsend bot posts fires the `issue_comment` trigger and a skipped run
(the `/fs-` prefix gate). Harmless, but the Actions list fills with skipped entries, which
obscured real signal (e.g., the F7 skip) during debugging.

### Agent-quality observations (GLM 5.3, effort high, via EnMaaS)

- **Triage:** genuinely good. Read the actual codebase, referenced real types
  (`DocumentStore`, `TabSidebarView`), made a reasonable build-vs-dependency
  recommendation, proposed concrete test cases.
- **Code:** produced a complete, mostly-working feature with tests — but also one real
  logic bug and a failing test it never ran (F8). Quality: acceptable first draft, not
  merge-ready.
- **Review:** the strongest performer — with a significant caveat (F11). Caught the
  high-severity logic bug, verified it against the PR's own test expectations, checked
  git history for the prior revert of the same feature, and — once `AGENTS.md` landed —
  enforced repo conventions (layering, fixtures, parameter labels). Round-over-round it
  correctly verified resolved findings. However, it also **prescribed remediations that
  do not compile on the target platform** (an iOS-only accessibility API recommended for
  a macOS app), which the fix agent then implemented verbatim. Review findings' problem
  descriptions were reliable; their remediation snippets were not.
- **Fix:** effective at resolving targeted findings (12/14 in round 1), but each round
  introduced new low-severity material for the next review (driver of F1), and round 3
  introduced a compile error by following the reviewer's bad remediation (F11).
  Compliance with scoped instructions is precise but per-run (F1 extension). **First
  post-CI data point (PR #9, iteration 5, ~90 minutes after CI went live): the fix
  report references CI as ground truth** — "the macOS CI job (build-and-test) is green
  on the prior head and will re-verify this commit on push" — while still correctly
  disclosing that the sandbox itself cannot run Swift. The retro's central validation
  criterion (agents reference CI status instead of only "tests could not run") was met
  on the first fix round that had a CI to reference.
- **Retro:** excellent, and the strongest validation of the evaluation. From workflow
  data alone (no access to this findings document), it reconstructed the entire PR #3
  saga accurately — 7 review rounds, 6 fix iterations, every "tests could not run"
  caveat, the iOS-only API remediation chain, the uncompilable head, the human's local
  catch and exact fix, even that TASKS.md's Verify section was left unchecked at merge —
  and filed **issue #8 proposing exactly the F8/F11 remedy**: a minimal macOS CI
  workflow (`swift build` + `swift test` on `pull_request`/`push`), with validation
  criteria, a cost note on macOS runners, and deduplication searches across three repos
  to confirm no existing issue covered it. The retro's diagnosis ("the arbiter is a
  human's local machine") and predicted impact ("likely collapsing the loop by several
  rounds") match the human analysis.
- **AGENTS.md works as a prevention mechanism:** review round 1 findings were mostly
  convention violations the agent had to be told about; after `AGENTS.md` landed, rounds
  cited it explicitly and the code agent's later output followed the conventions from the
  start (fewer pattern-inconsistency findings per round).

### Cost

Per-run inference cost is reported in each agent's status comment. Observed: review runs
$2.01–$3.32, fix runs comparable. Ballpark total for the exercise (≈6 agent runs of
substance plus triages): roughly **$15–25** of gateway inference. Loop iterations dominate
cost (F1).

---

## 4. Recommendations

1. **Keep the "what to fix" decision; delegate only the "how."** The observed
   suboptimal pattern was bare `/fs-fix` (mandate: "fix everything flagged") once
   severity was already down to lows. The alternatives, in order of leverage:
   - **Severity-filtered scoped instructions**: `/fs-fix only the high and medium
     findings; do not address low-severity findings` — caps churn, keeps the next
     diff small.
   - **`/fs-fix-stop` after the mediums are gone** — the only lever against
     review-verdict-auto-triggered rounds (3 of the 6 in this exercise); human
     `/fs-fix` remains available.
   - **Stop and triage**: once no mediums remain, merge and file the lows as a
     follow-up issue (done here: issue #5) instead of spending more rounds.
   - **Lower `ITERATION_CAP`** (default 5) to 2–3 to match the observed convergence
     curve — escalation fires rounds sooner.
   For reference, the optimal sequence here would have been: scoped fix for the two
   mediums → `/fs-fix-stop` → merge: **2 fix rounds instead of 6**.
   *Caveat from day 3 (F14): scoped instructions can only shape rounds ≥2 — the first
   fix after a review verdict is bot-triggered within ~a minute, before a human can
   read the review, and a late instruction makes the next run revert round 1's work to
   comply. If the scoping matters, post it knowing round 1 is already lost — or skip
   straight to `/fs-fix-stop` and re-scope manually.*
2. **Add Swift CI** (`swift build` + `swift test` on `pull_request`, macOS runner) before
   the next agent-authored PR. This is the single highest-leverage change — F8 and F11
   (five fix rounds iterating on code that never compiled) are both direct consequences
   of its absence.
3. **Keep rulesets scoped to `main` only** (already done). Document the interaction (F5)
   if rulesets are added elsewhere.
4. **File the carried substantive findings as issues** rather than more fix rounds:
   the SwiftTerm exit-127 failure-path conflation is the main one; the rest
   (accessibility focus/announcements, ⌘R label, confirmation-scope copy) are polish.
5. **Consider a setup verification step** in fullsend (apps installed, agents override
   present, gateway reachable) — F2/F3/F4 were all setup-time failures discoverable in
   seconds with a preflight check.
6. For future evaluations: capture the `/fs-fix` command format requirement (no leading
   space) and the phantom-run workaround (F7, F9) in runbooks so they don't cost debugging
   time again.
7. **"Calm repo" configuration — worked out, verified against the docs, deliberately
   not applied during the evaluation.** The evaluation is of fullsend's *defaults*;
   disabling default behaviors mid-evaluation would contaminate it. Recorded here so
   the recipe is actionable afterward (or as a phase-2 experiment: apply it and evaluate
   whether the calm repo loses anything the auto-loop was catching). The goal: every
   write-capable or spend-bearing agent runs only on explicit human command.
   - **Stop auto-code promotion** (F12): `TRIAGE_AUTO_CODE` is a harness env var in
     upstream `fullsend-ai/agents/harness/triage.yaml`, not a config.yaml key. Override
     via `base:` composition — register the triage agent with a small local harness
     that pins the upstream file (commit + `#sha256=`) and sets `TRIAGE_AUTO_CODE:
     "off"` in **both** `env.runner` and `env.sandbox` (the post-script applies labels;
     the agent recommends them — both read the var and must agree). Triage then labels
     qualifying issues `triaged` instead of `ready-to-code`, and `/fs-code` remains the
     human gate.
   - **Review on command only**: a `trigger` on the `review` entry in config.yaml
     replaces its default stage routing (auto-review on every PR open/push/label).
     Gate it to `/fs-review` from a human. Tradeoff: the fix→review quality loop
     becomes the human's responsibility; CI covers the mechanical checks.
   - **Retro on command only**: same pattern, `/fs-retro` — no agent run on every merge.
   - **Not controllable on GitHub** (documented): `code` and `fix` have no
     config-triggerable routing; fix auto-fires on CHANGES_REQUESTED verdicts. Levers
     remain per-PR (`/fs-fix-stop`), the iteration cap, and process discipline (rec 1).
   - **Emergency stop**: `kill_switch: true` in config.yaml disables everything,
     instantly and reversibly.
   - **Per-PR, no config needed**: `/fs-fix-stop` on any PR kills bot-triggered fix
     rounds (human `/fs-fix` still works); remove the label to re-enable.
   Local artifacts: `.fullsend/config.yaml.orig` (byte-identical archive of the
   pre-change config) and `config_options.md` (working notes) — kept uncommitted.

---

## 5. Final state

*(Updated 2026-11-13 ~15:00 UTC.)*

- **PR #3 merged** (2026-11-12 ~17:15 UTC, by the human). Final head merged: `b7bdd56`.
  The loop terminated at its iteration cap: 7 review rounds, 6 fix rounds, 1 compile
  verification by the human.
- **PR #9 merged** (2026-11-12 22:57 UTC) — the auto-coded exit-127 fix, after its own
  loop run (merge-conflict resolution, the F1 per-run-instruction extension). Issue #6
  closed by the merge. Retro auto-fired (observation #3).
- **PR #12 merged** (2026-11-12 22:58 UTC) — the CI least-privilege fix. Retro
  auto-fired (observation #4), correctly reconstructing the F13 chain in its write-up.
- **CI is live on main** (PR #11, `a76376c`): `swift build` + `swift test` on macos-26,
  every PR and push. 135/135 tests on main; issue #8 closed.
- **PR #14 open and in an active fix loop** (issue #4's implementation, ~1,341 lines):
  coder → review (16 findings) → bot fix (all 16, including lows) → human's scoped
  instruction arrived 25 min late (F14) → fix iteration 2 reverted the lows to comply →
  CI red on all three commits (4 worktree-test failures the agent cannot reproduce,
  F15). Review round 3 in flight as of 14:19 UTC. Levers: a scoped `/fs-fix` with the
  root cause pasted inline, `/fs-fix-stop`, or human diagnosis of the CI failure.
- **The evaluation continues with all defaults on** — see recommendation 7.
- Issues open: #4 (PR #14 pending). Zombie run 43095470483 still queued (harmless).
- Local artifacts: test worktree `../dev-buddy-pr3` (removable), uncommitted
  `.fullsend/config.yaml.orig` and `config_options.md` (recommendation-7 working
  material).

---

## 6. Appendix: retro agent output (issue #8, filed 2026-11-12 17:40 UTC)

The retro's full analysis on the merged PR #3, preserved for reference. Notable because
it was produced from workflow data alone, with no access to this findings document, and
independently reached the same conclusions as F8/F11.

**What happened (retro's reconstruction):** PR #3 went through 7 review rounds and 6 fix
iterations; every agent fix report carried the caveat that `swift build`/`swift test`
could not run (Linux-only sandbox, macOS 14/AppKit target). The repo had no CI at all.
A review-agent remediation suggested an iOS-only accessibility API, the fix agent
implemented it verbatim (visible by iteration 5, head `3332755`), and the PR head did
not compile on macOS. No automated check caught it across the entire ~24 h loop; the
human caught it with a local `swift build` and supplied the exact fix
(`AccessibilityNotification.Announcement(message).post()`), applied as iteration 6
(`b7bdd56`). TASKS.md's Verify section was left unchecked at merge, unlike every prior
feature.

**Retro's diagnosis:** "The single highest-leverage gap: AGENTS.md makes `swift build`
+ `swift test` the arbiter ('Both must pass'), but nothing in the pipeline can execute
them, so the arbiter is a human's local machine. A macOS CI gate would have caught the
compile break deterministically at the first offending fix iteration, likely collapsing
the loop by several rounds and removing the need for the human's only code-level
intervention. It would also let the review/fix agents treat CI status as ground truth
instead of 'tests: could not run'."

**Retro's proposed change:** add `.github/workflows/ci.yaml`, triggered on
`pull_request` (opened/synchronize) and `push` to main, running `swift build` and
`swift test` on a `macos-14` (or `macos-latest`) runner with a recent Swift toolchain —
minimal, no caching complexity. Optionally update AGENTS.md's "Verify before you
finish" section to tell agents that CI is the build/test arbiter and TASKS.md Verify
items may reference the CI run when the sandbox cannot execute Swift.

**Retro's validation criteria:** CI runs appear on the next 5 PRs (agent or human); any
commit that does not compile on macOS fails the check before or during the first review
round; within the next 3 agent PRs, fix/review reports reference CI status instead of
"tests could not run", and TASKS.md Verify sections get checked against CI evidence.

**Retro's deduplication:** searched open and closed issues across dev-buddy,
fullsend-ai/fullsend, and fullsend-ai/agents; considered #4, #5, #6, #7; confirmed no
existing issue proposes CI/build automation.

**Cost consideration (retro's, plus human math):** the retro flagged that macOS runners
cost more Actions minutes than Linux and left the cost/coverage tradeoff to the owner.
Concretely: GitHub bills macOS runners at 10× the Linux rate, so the Free plan's 2,000
included minutes are effectively ~200 macOS-minutes/month. The suite ran in ~0.1 s with
a full build under a minute locally, so each CI run should cost roughly 2–5 billed
minutes — sustainable at this repo's PR volume, but worth monitoring if agent loops
generate many pushes.

**Human assessment:** the retro's diagnosis, proposed remedy, and predicted impact
match this document's F8/F11 exactly. The loop audited itself and prescribed the correct
fix for its own biggest failure mode — the strongest single result of the evaluation.
