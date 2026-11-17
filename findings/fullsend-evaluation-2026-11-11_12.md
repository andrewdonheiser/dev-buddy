# Fullsend Evaluation — Findings & History

**Purpose:** evaluate Fullsend (https://fullsend.sh/), an agentic SDLC platform, by running
its full triage → code → review → fix loop end-to-end on this repository, using GLM 5.3 at
high effort via the EnMaaS inference gateway.

**Evaluation window:** 2026-11-11 ~16:00 UTC → ongoing (document last updated 2026-11-16
~16:30 UTC; the core loop evaluation completed ~17:30 on day 2, follow-on observations
continue — see timeline and recommendation 7)
**Fullsend version:** v0.55.0 · per-repo install mode · `pi` runtime
**Status at time of writing:** core evaluation complete (PR #3 merged after the loop
self-terminated at its iteration cap); follow-on phases: CI added and green (PR #11),
auto-promoted PRs #9/#10, workflows-permission case study (F13), PR #14's full
fix loop (F14–F17) converged, merged, and its lows archived as issue #16 (F18), the
merge's autonomous chain retro → issue #18 → auto-coded PR #19 (F12 capstone), and
day 4: PR #19 merged — its AGENTS.md policy validated on the first fix round while
the deferral gap it prescribes shipped a verified defect to main (F18 day-4
capstone, now being remedied as auto-coded PR #22). PRs #21 (the human's browser
feature) and #22 open. **Defaults deliberately left on for continued observation** —
see recommendation 7.

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
  the loop's ignition. Sharpest form of the gap: **agents react to CI's verdict but
  cannot see its step output** — the compiler's diagnosis sits in logs no agent
  consumes, and the only channel between fullsend's CI side and its agent side is a
  human copy-pasting error text. Caveat: the blindness is partly this repo's macOS
  boundary (see Scope note); the missing CI→agent log channel is general.

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
- **No default path defers remaining findings to a tracked issue** (F18): the loop
  terminates (cap, `/fs-fix-stop`, merge) without capturing the leftover lows
  anywhere durable — filing the collector issue itself dispatches triage within
  seconds (the archive had to be defended by canceling the run at the gate), and
  even a repo-local policy that prescribes the deferral gets it executed by nobody:
  the first finding deferred under the new AGENTS.md policy was a verified defect
  (a broken autolink in the policy's own text) that shipped to main via a silent
  merge. The asymmetry: humans have no opt-out; bots (whose filings sit quiet until
  they add `ready-for-triage`) have an opt-in.
- Scaffold-branch config doesn't reliably survive into `main` (F3); missing GitHub App
  installation is a silent no-op (F4); rulesets targeting more than the default branch
  block agent pushes entirely (F5).
- **The verification gap is symmetric** (F20): the human-directed close-out — locally
  green, 189/189 — red CI'd twice on failures in code it never touched: a test whose
  cleanup deleted the shared temp directory, and 2-second deadlines losing to a ~5x
  runner stretch. Twice in one day a test also passed *vacuously* (JSON `\/`
  escaping no-op'd a fixture rewrite; the one repo-name shape that fit the wrong
  guard) — once caught only by the review agent, which found a real high-severity
  regression the author's own test missed. "It passes locally" is blind in both
  directions; the loop's reviewer earned its keep as the second set of eyes.

**Low / informational**

- `/fs-fix` with a leading space silently no-ops (F7); phantom queued run (F9); every
  bot comment spawns a skipped workflow run (F10).
- **A completed run can report "❌ Terminated"** (F19): the review's status-token mint
  timed out *after* the verdict was submitted and the loop continued — the work
  succeeded, the status failed. The human-facing signal is now unreliable in both
  directions (F2's mirror: silent failure vs. false failure).

**What worked well**

- Scoped `/fs-fix` instructions are followed precisely, within their run.
- Triage: cheap ($0.07–0.12), verifies claims against the code, decomposes collectors
  into single-purpose issues, corrects errors in the human's filed text.
- Retro: from workflow data alone, independently reconstructed the PR #3 saga and filed
  the exact CI remedy this document's F8/F11 prescribe.
- **Retro (day 3 capstone): read this evaluation document on `main` and proposed
  implementing it** — issue #18 codifies the no-lows policy, cites F1/recommendation 1/
  the issue #16 collector pattern as evidence, searches for duplicates including
  upstream fullsend issues, and flags its own main uncertainty (standing policy vs.
  per-PR instructions). The findings doc influenced an agent's proposal within a day
  of being merged.
- **The review-finding policy validated itself on its first live round** (day 4): the
  bot-triggered fix on PR #19 made no changes, cited the policy for the three lows,
  and correctly routed the protected-path medium to human sign-off — zero churn, zero
  intervention, the exact behavior PR #14's loop lacked. The review agent's protected
  -path gate also worked as designed: it structurally cannot approve AGENTS.md
  changes, and the human's merge supplied the sign-off. The retro's merge analysis
  (day 4) then correctly priced the whole chain (~$1.88, ~32 min) and named the
  deferral gap — the platform's own agents diagnose the platform's gaps precisely.
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
| 21:20 | **Retro files issue #13** (the unaddressed findings from PR #11's review). Being bot-authored, its `issues.opened` does not trigger triage — the human guard — so it sits untriaged and unlabeled. |
| ~21:30 | Human posts `/fs-fix merge main into this branch and resolve the conflicts…` on PR #9 (the conflict from PR #10). The fix agent merges `main` (`a76376c`, carrying PRs #10 and #11) and resolves the test-file conflict, preserving both sides. **PR #9 conflict resolved.** |
| 21:41 | The merge commit auto-triggers review round 5 on PR #9: CHANGES_REQUESTED, 5 lows (the same carried ones). The push also triggers the **first CI run on a PR branch** — green. |
| ~22:00 | **Instruction-scope discovery (F1 extension):** the review verdict auto-triggers fix iteration 5 (**bot-triggered, no instruction**), which "Addressed all 5 open findings" — all lows — directly contradicting the human's 19:41 "do not fix any low issues" instruction. That instruction was obeyed exactly by its own run (iteration 4 made no changes and filed the lows under "Disagreed"), but **`/fs-fix` instructions are per-run**: the next bot-triggered round starts fresh with the default "fix everything flagged" mandate. Only the code persists across rounds, not the guidance. |
| 22:11 | Review round 6 on PR #9: CHANGES_REQUESTED again. Loop active. Notably, iteration 5's report references CI: *"the macOS CI job (build-and-test) is green on the prior head and will re-verify this commit on push"* — **the first agent report in the evaluation to treat CI as ground truth**, ~90 minutes after CI went live. The retro's central validation criterion is met (see agent-quality observations). |
| 22:24 | **The retro adds `ready-for-triage` to #13 itself** — the label path has no actor check, by design (it is how triage routes its own sub-issues into the pipeline). Triage dispatches within seconds and, at 22:27, aptly labels #13 `pr-open`: it notices PR #12 already addresses the findings rather than decomposing them. (**F18 mirror image:** bot filings are quiet until explicitly promoted — see the issue #16 case study on day 3.) |

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
| 14:55 | Review round 2: CHANGES_REQUESTED on iteration 2's head. Fix iteration 3 (bot-triggered) follows. |
| ~15:09 | Fix iteration 3 completes: resolves the remaining medium findings and the 4 worktree-test CI failures — **CI green on the PR for the first time** (final head `a7b68a9`; CI stays green from here). |
| 15:50 | Review round 3: CHANGES_REQUESTED, findings down to lows. Fix iteration 4 (bot-triggered, no instruction) makes **no changes**, citing the maintainer's standing "do not fix low priority or nits" comment from the history (the F1 refinement). |
| 16:39 | Review round 4 (final): **25 findings, all low**. Fix iteration 5 likewise makes no changes on the standing instruction. **Loop converged**: no high or medium findings remain. Per the F1 playbook, the 25 lows are archived (see 17:48) rather than spent on further rounds. |
| ~17:29 | Human merges **PR #15** (findings F14–F17 batch) — `main` at `88b2ae4`. The merge fires the usual autonomous noise: retro dispatch plus skipped runs on every bot comment (F10). |
| 17:48 | **Issue #16 filed — collector archive of the 25 lows** (F18 case study). Triage dispatched within **4 seconds** of filing; run `43476454053` was canceled ~2 minutes in, before the agent produced any output. The issue is kept dormant: no labels, no decomposition, body never edited (edits re-trigger triage). |
| 18:16 | **Human merges PR #14** (`6f2d366`) after the local smoke test; issue #4 auto-closes. Retro auto-fires on the merge (observation #5). |
| 18:23 | Human files **issue #17** ("browser behavior" — two feature requests from the smoke test: a browser option in the nest context menu; in-app browser tabs instead of opening Safari). The filing auto-dispatches triage (the F18 no-opt-out, benign this time): it runs 18:24–18:27 and replies with a clarifying question about link-handling behavior. |
| 18:39 | **Retro files issue #18**: codify the "do not fix lows" policy in AGENTS.md — citing this evaluation document's own findings (F1 Refinement, recommendation 1, the issue #16 pattern) as its evidence. Adds `ready-for-triage` itself (the bot opt-in). |
| 18:44 | Triage on #18 labels it `documentation` + `ready-to-code`. |
| 18:49 | **Auto-code chain completes (F12 capstone): the coder opens PR #19** — "Add review finding policy to AGENTS.md" (`AGENTS.md`, `TASKS.md`). CI green in 3 minutes; the review agent fires on the PR automatically. **Seven autonomous steps from one merge, zero human input.** |
| 18:45–19:00 | Human answers #17's clarifying question (18:45) and re-triggers triage on it (18:58–18:59, via a typo'd `/fs-traige` comment and an issue edit); triage in flight on #17 at time of writing. |

### Day 4 — 2026-11-16: the policy validates itself, then ships a defect

| Time (UTC) | Event |
|---|---|
| 19:05 (day 3) | Review on PR #19: CHANGES_REQUESTED — 1 medium + 3 lows ($1.29, 15.5 min). The medium is a **protected-path gate**: AGENTS.md changes always require human maintainer approval; the review agent structurally cannot approve them. Lows: (a) bare-`/fs-fix` ambiguity in the override clause, citing this document as evidence; (b) a broken autolink — bare `#1760` in AGENTS.md:99/TASKS.md:148 links to a nonexistent local issue instead of fullsend-ai/agents#1760; (c) no security carve-out — the policy defers low-severity *security* findings too, and issue #16 already archives real path-containment ones (`WorkUnitStore.swift:94,101,231,233`). |
| 19:11 (day 3) | **The policy passes its first live test:** the bot-triggered fix round makes **no code changes** — the medium is recorded as requiring human sign-off (which the agent cannot grant), the three lows are deferred as disagreements *citing the new AGENTS.md policy*. No fix-then-revert pair, no human intervention ($0.23). CI green throughout. |
| 13:45 | Human runs `/fs-code` on issue #17 (the browser feature request) → coder runs → **PR #21** opens at 14:04 ("add in-app browser tabs nested under review units"). Human-initiated, not auto-code (#17 was triaged `feature`/`enhancement` — outside the auto-promotion categories). |
| 13:46 | **Human merges PR #19** (`90e4ef6`) — the merge *is* the sign-off the protected-path medium required, 2.8 days after the review. Issue #18 auto-closes. **The broken `#1760` autolink ships to main:** a defect verified accurate by two independent agents, deferred per policy, never fixed, never archived. |
| 13:47–13:56 | Retro fires on the merge ($0.60): calls PR #19 "the cleanest agent run in this repo's history" — full chain ~$1.88, ~32 min triage→fix-complete. Flags four cracks: (1) the deferred-into-oblivion autolink, and — the sharper point — **the policy's deferral step was executed by nobody**: issue #16 still holds only the 25 PR #14 findings, the 3 deferred lows exist only in a buried PR comment; (2) the fix round was a $0.23 no-op that existed only to announce it could not act (evidence for upstream fullsend#8139/agents#1110); (3) the PR sat 2.8 days blocked solely on the human-approval gate (evidence for fullsend#7186); (4) CHANGES_REQUESTED for a low-heavy verdict (agents#1141). Files **issue #20**: make the deferral durable (append to archive #16) and exempt PR-introduced objective defects. |
| 14:00–14:08 | Triage on #20 (via the retro's own `ready-for-triage`): labels `documentation` + `ready-to-code` → **auto-code fires → PR #22** (14:08, "Make low-finding deferral durable in the review policy"). The remedy for the deferral gap is itself delivered by the default autonomy chain. |
| 14:56 | Reviews land on both open PRs: PR #21 CHANGES_REQUESTED (fix loop follows — bot-authored PR); PR #22 reviewed (commented). Fix activity in flight on #21 at ~15:22. |
| 15:30 | Fix iteration 1 on PR #21 (human-triggered): resolves a merge conflict with `main` (bringing in the AGENTS.md policy) and fixes both medium findings from the 14:29 review. |
| 15:31–16:03 | Review round 2 on the new head `35df69e`: the agent completes its full workload — verdict submitted 16:02:33 (CHANGES_REQUESTED: 1 new medium + 10 lows), labels applied, `run_health=1.00` — but the status comment reads **"❌ Terminated"** because the status-token mint timed out after the work was done (**F19**). The GitHub Actions job is green; the false failure exists only in fullsend's status layer. |
| 16:04–16:10 | The submitted verdict auto-triggers fix iteration 3 (bot): fixes the medium edge-case (browser/terminal close fallback chain). |
| 16:11 | **Human merges PR #22.** Issue #20 auto-closes; the durable-deferral policy (objective-defect exception + append-to-#16 executor) is live on `main`. Retro will fire on the merge. The policy's first real test is the next fix round on an agent PR. |
| ~17:44 | **EnMaaS API key rotated** (repo secret updated 17:44:49 UTC) after the old one was invalidated. Transient `pull_request_target` startup failures around the rotation; 4+ successful agent runs after prove the new key. The evaluation session's own `gh` auth broke (stale token in the environment) and was restored by re-sourcing `~/.zshrc`. |
| ~17:00–19:20 | **PR #21's loop grinds to its cap.** Bot fix iterations continue through compile-error and CI-failure rounds; the human drives **three scoped `/fs-fix CI is red…` rounds**, each pointing the fix agent at the failing run. Result (F15 resolution): **the fix agent can fetch and quote CI logs when a instruction names them** — commits `5d1bc77`, `ced01fb`, `6e99575` each cite CI error text — but nothing wires CI output into the agent's context unprompted. At 19:20 CI is green on `6e99575` (184 tests, run 43938363500) and the standing review is all-13-low: merge-ready by the policy's stopping rule. The bot's next two fix attempts are **cap-blocked** ("iteration 6/7 exceeds bot cap of 5. Escalating to human."). |
| 20:25 | **Close-out begins on human authority** ("fix and push the real ones"): **PR A pushed** — `0156f21` on `agent/17-browser-tabs`, the 7 real deferred lows (active-unit resolution for browser tabs, in-app routing for the review overview's PR button, nesting-aware session/saved-view persistence, fail-closed scheme allowlist in both the router and the web-view delegate, a load-failure accessibility announcement, sidebar orphan fallback; +269/−37, +5 tests, 189/189 local). The other 6 deferred lows are design/preference calls (naming, api-shape, selection-model direction). |
| 20:27 | **CI on `0156f21` red — both attempts** (20:27, 20:49): ~10 failures in suites PR A never touched (work-unit, chat, terminal timing), clustering in one ~3.2s window, with identical-shape tests passing in the same run and the same commit green locally. (Root cause: F20, below.) |
| 20:40 | **PR B opened — #23** (`fix/16-work-unit-store-defects`, `37c6e23`): the real defects archived in issue #16 — the percent-decoded-slug force-unwrap crash, the flattened single-component unit directory, a shape-checked delete guard, unreadable-records rotation instead of silent overwrite, withheld-persistence recovery, published save failures, typed git errors. 8 new tests; **two initially passed vacuously** (F20). |
| 20:43 | **PR C opened — #24** (`fix/13-ci-determinism-and-docs`, `1ae6c74`): issue #13's leftovers — `version.plist`-based Xcode selection (the bare `Xcode.app` could never win the lexicographic name sort) with a Swift ≥ 6.2 gate, `persist-credentials: false`, the AGENTS.md CI-verification sentence, the TASKS.md feature entry. Closes #13. |
| 20:56 | **CI root cause 1 fixed** (`584c51a`): the human agent's own new test had placed its scratch folder directly in the shared temp directory and its cleanup `defer` deleted **the entire temp root** — wiping every concurrently running test's scratch state. Invisible locally (fast machine, different interleaving, `try?` swallowing the partial failure); fatal on loaded runners. The filesystem collateral vanishes from CI. |
| ~21:05 | **CI root cause 2 addressed** (`6a64ec5`): the remaining failures were 2-second deadlines losing to main-actor contention (the whole test process stretched ~5x; a 5-second exit-127 wait passed but its launch-window classification flipped). `waitUntil` headroom 2s→10s; the exit-127 test gets the fixed clock its 126 sibling already used. **CI green.** A control rerun of the old green head `6e99575` also stayed green — so whether the +5 tests tipped the load or the runner pool did stays ambiguous; both fixes are correct either way. |
| 21:15–21:44 | **Review on `6a64ec5`** ($3.02 — the most expensive round of the evaluation): **all low** (16 new + the 13 deferred). One real item: the default browser-session factory does not forward the store's external-opener injection. The follow-up bot fix is cap-blocked again. |
| ~21:50 | Findings-doc batch through day 4 committed locally; session pauses. |

### Day 5 — 2026-11-17: the close-out lands

| Time (UTC) | Event |
|---|---|
| ~12:30 | **Review-response fixes on all three PRs.** PR #21 `c7a0ce8`: the external-opener seam is forwarded into browser sessions, and the navigation policy is extracted into a testable routing function with coverage for the previously untested `decidePolicyFor` branches. PR #23 `1d19676`: **the review's high-severity catch** — the legacy-layout delete guard used the wrong shape (`<owner>/<owner>-<repo>-…` instead of the `<owner>/<repo>-…` the base code actually generated), so legacy directories with dashless repo names — the common case — were never cleaned up on delete; and the human's own test had used a dashed repo name, passing vacuously. PR #24 `9034596`: `set -euo pipefail`, a glob no-match guard, a step rename, and TASKS.md evidence with the true count — the reviewer had recomputed **156 tests / 21 suites** from the tree after the human's PR body claimed "77 tests, 11 suites" (a `swift test \| tail` artifact: the pipe shows only the last target's summary). |
| 12:36–13:14 | **Final reviews:** PR #21 `$3.01`, CHANGES_REQUESTED with low-severity findings only; the fix loop stays cap-blocked (iteration 8). PR #23 and #24 reviews complete. All three PRs CI-green and mergeable. |
| 14:09–14:11 | **Human-directed merges: #23, #24, #21** (in that order; #21 last, still mergeable after the other two). Issues **#13 and #17 auto-close**. Post-merge cleanup: all merged remote branches deleted (including the ten stale ones from earlier PRs), five local worktrees removed, local main rebased. Only issue #16 (dormant archive) remains open, by design. |

---

## 3. Findings

Severity here reflects impact on the evaluation, not fullsend's own severity scale.

### Product / platform findings

(Numbered by discovery order; F11 was found on day 2 during local build verification,
F12 at wrap-up when triage auto-promoted issue #6 to code, F13 from the workflows-
permission push rejection on the `/fs-code` run against issue #8, F14/F15 on day 3
from the PR #14 fix loop — the instruction race and red-CI churn respectively — F16
from issue #4's stale `blocked` label, F17 from reading PR #14's review trail on
GitHub, F18 from the docs check for a findings-deferral function, F19 from the
"❌ Terminated" status comment on PR #21's second review round, and F20 from the
day-4/5 close-out's CI investigation of the human-driven fix batch; the last six are
day 3–5.)

### Scope and generalization

This evaluation ran on a worst-case target, and the findings should be read with
that in mind. The target is a macOS app (SwiftUI, AppKit, WKWebView, SwiftTerm);
fullsend's sandbox is a pinned **Linux container** — per-repo config offers no
sandbox-image or macOS option at all. Swift-the-language runs on Linux, but this
app's frameworks exist only on macOS: **no Linux sandbox image, custom or not, can
ever compile this repo.** Fullsend's home turf is the opposite case — Linux-stack
repos (Go, Python, Node, Rust), where the sandbox runs the project's test suite and
the code/fix agents self-verify before pushing.

What that splits into:

- **Stack-independent findings — generalize to any repo:** F1 (non-convergence),
  F2–F7, F9, F10, F12 (autonomy chains), F13, F14 (instruction race), F16 (stale
  labels), F17 (fragmented review output), F18 (deferral gap), F19 (false
  "Terminated"), F20 (the symmetric verification gap — locally-green code reds CI
  whoever wrote it, and vacuous tests hide it). None of these depend on what
  language the repo is written in.
- **Stack-amplified findings — read with the caveat:** F8 (partially), **F11 and
  F15** — every instance of "the agent pushed code it could not verify." In a
  Linux-native repo these largely cannot happen: the sandbox is a CI-equivalent, so
  blind pushes are caught and corrected in-sandbox before they reach a PR. What
  *remains* of F15 in any repo: CI failures the sandbox cannot reproduce (toolchain
  version skew, runner-only services, flaky network tests) — and the general core:
  **agents react to CI's verdict but cannot see its step output.** The diagnosis CI
  writes into its logs never enters any agent's context; the human is the only
  channel, copy-pasting error text between two of the platform's own subsystems.

The macOS case is not an unfair test but the revealing one: it isolates the
verification boundary. When the sandbox cannot check the work, what remains is
review-only iteration plus a CI gate whose output never reaches the loop — and the
human becomes the compiler-error courier. That applies to any macOS/iOS/Windows-
targeting repo, and to any repo whose CI needs runners the sandbox cannot emulate.

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

**Day-3 capstone: the entire chain fired from a single merge, zero human input — and
the payload was a proposal to curb autonomy.** After the human merged PR #14 (18:16),
the retro fired automatically, analyzed the PR's fix-loop saga, and filed issue #18
(18:39): codify the "do not fix lows" policy in AGENTS.md. Its write-up cites this
evaluation document directly (F1's "Refinement" passage, recommendation 1, the issue
#16 collector pattern) — the retro read the findings on `main` and proposed
implementing them. It added `ready-for-triage` itself (the bot opt-in, F18); triage
ran (18:44) and labeled it `documentation` + `ready-to-code`; `documentation` is an
auto-code category, so the coder opened **PR #19** (18:49) implementing the policy;
CI green in three minutes; the review agent fired on it automatically. Merge →
retro → issue → triage → auto-code → PR → review: seven autonomous steps from one
human action — and the content was the retro's own remedy for fix-loop overreach,
delivered by autonomous coding. Benign again (the PR implements this document's
recommendations), but the count is now: three unrequested agent runs in one evening
(day 2), and a seven-step autonomous chain from a merge (day 3).

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

**The mechanism, precisely: agents react to CI's verdict but cannot see its step
output.** The fix agent's inputs are the review body and the `/fs-fix` instruction
text — nothing in the pipeline injects CI's logs. The diagnosis (compiler errors with
file:line, failing test names, assertion messages) is written by CI into logs no agent
consumes; the agent sees at most the red/green status. The only channel between
fullsend's CI-facing side and its agent side is a human copy-pasting log text into a
comment — platform knowledge nothing teaches, and domain knowledge the human doesn't
need (the compiler's message *is* the diagnosis; the agent has the expertise to act
on it, if it ever receives it). Day-4 recurrence (PR #21, third observed instance
after PR #3 and PR #14): fix iteration 3 shipped a Swift compile error
(`'self' used before 'super.init' call`, `BrowserSession.swift:52,54`) — fully
described in the CI log, invisible to the agent that authored it, and recoverable
only by a human relaying the error text the human cannot interpret.

**Generalization (see "Scope and generalization" below):** the blindness is
stack-specific — this repo is a macOS app that no Linux sandbox can compile, ever —
but the missing CI→agent log channel is general. In a Linux-stack repo the gap is
usually masked (the sandbox reproduces the failure, so the agent self-diagnoses); it
surfaces whenever CI fails for anything the sandbox cannot reproduce.

*What would break the cycle:* red CI suppressing bot-fix ignition (routing the PR to
`needs-human` instead — the failure is, by definition, not fixable-blind); feeding
failed-run logs into the fix agent's context (the diagnosis already exists — CI wrote
it down; the loop just never reads it); or a sandbox that can run the project's tests
(macOS runners for macOS projects, or remote-verification against CI as part of the
fix loop rather than after it). Absent either, the practical rule for the human:
**when CI is red on a bot PR, the next fix round is guaranteed to be a guess — stop
it (`/fs-fix-stop`) or diagnose it yourself.**

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

**F18 — No default path defers remaining findings to a tracked issue (medium; design
gap — upgraded from low after the day-3 case study).**

The loop's terminal states — iteration cap, `/fs-fix-stop`, merge — none of them
capture the remaining findings anywhere durable. They survive only as inline comments
on a merged PR's diff (see F17 on how invisible those are). The collector-issue move
— file one issue listing the lows, merge, move on — is a human step every time:
issue #5 after PR #3, and issue #16 for PR #14's 25 lows (see case study).

The notable part is that the platform has every ingredient except the wiring:

- The CLI ships issue management — `fullsend issues create`, `get`, `post-comment`,
  `link` — across GitHub, GitLab, and Jira.
- The retro agent demonstrably creates issues (it filed issues #8 and #13); the
  primitive is agent-reachable.
- The convergence pattern that produces leftover lows is established and predictable
  (F1).

But the review/fix loop has no "defer the remainder to a follow-up issue" mode — the
fix agent's mandate vocabulary is fix-or-disagree. An open experiment: whether a
scoped `/fs-fix` can instruct the agent to file the collector itself (the retro agent
has the tooling; the fix agent's toolset is unverified).

**Case study (day 3, issue #16): the collector had to be fought in.** When the 25
remaining lows from PR #14 were archived as issue #16, the filing itself dispatched
triage within **four seconds** — `issues.opened` with a human actor matches the
triage trigger, and every human-filed issue does. There is no opt-out: no label
suppresses the dispatch (the pre-script strips triage-related labels and proceeds
regardless), and no dormant or archive mode exists. The issue was kept inert only by
**canceling the dispatch run ~2 minutes in**, before the agent produced any output —
no labels, no decomposition; the only trace is the runner's own "⚠️ Cancelled"
status comment. Dormancy also imposes standing rules on the human: never edit the
issue (human edits re-trigger triage via `issues.edited`), and never add the
`ready-for-triage` label (an explicit trigger). Any other label merely fires a
harmless skipped run.

The mirror image is issue #13 (the retro's filing from the PR #11 merge). Created by
the retro bot at 21:20, it sat untriaged for an hour — bot-authored `issues.opened`
does not match the trigger (the human guard). Only when the retro explicitly added
`ready-for-triage` at 22:24 did triage dispatch — the label path has no actor check,
by design, because it is how triage routes its own sub-issues into the pipeline. The
resulting triage was apt: it noticed PR #12 already addressed the findings and
labeled the issue `pr-open` rather than decomposing it.

**The asymmetry, both directions now observed: humans have no opt-out; bots have an
opt-in.** A human cannot file a quiet issue — every human filing enters the
pipeline, and dormancy requires canceling runs at the gate. A bot files quiet by
default and promotes its filings explicitly, by label. The collector move — this
document's own remedy for F1 — is therefore not merely unsupported but actively
resisted: the platform dispatches an agent to "help" with the very issue whose
purpose is to defer agent work.

**Day-4 capstone: even a repo-local policy prescribing the deferral doesn't get it
executed.** The AGENTS.md review-finding policy that PR #19 shipped (written by the
coder from the retro's issue #18, itself derived from this document) contains the
deferral as its third bullet: "Defer accumulated low findings to the dormant archive
issue (#16)." On the policy's very first live test, the fix agent obeyed the
disagreement rule (bullet 2) but no actor executed the deferral rule (bullet 3) —
the three deferred lows were never appended to issue #16, and exist only in a
comment on the merged PR. The bullet prescribes an outcome, not an owner: no agent
is assigned the step, no automation triggers it, and the human's silent merge
passed it through. Consequence, observed: a **verified defect shipped to main** —
the review agent found, and the fix agent independently confirmed, that the bare
`#1760` in the policy's own text autolinks to a nonexistent local issue instead of
fullsend-ai/agents#1760; the policy deferred it; nothing tracked it; the merge
shipped it. The policy's first deferred finding was a defect in the policy's own
documentation. The retro caught exactly this on the merge and filed issue #20
(make the deferral an executable step; exempt PR-introduced objective defects) —
which the default chain then auto-coded as PR #22, so the remedy for the gap is
pending in the same pipeline the gap lives in.

*Remedies:* a fix-agent instruction mode ("file the remainder as a follow-up issue
instead of fixing"), or auto-filing the collector on `/fs-fix-stop` or iteration-cap
termination. Either would close F1's loop cleanly: the human decision becomes "merge
now," and the leftovers are tracked by default rather than by memory. A quieter
complement: a label the triage pre-script respects (an opt-out for archive/reference
issues), which would have made issue #16 a one-command filing instead of a
run-cancel race.

**F19 — A completed run can report "❌ Terminated" (low; status accuracy — the mirror
of F2).**

*Case: the second review round on PR #21, 2026-11-16 15:31–16:03 UTC, run 43897126768,
head `35df69e`.*

The review agent completed its entire workload. The result was written to
`agent-result.json` and passed validation at 16:01:16 ("exit code 1 = request-changes");
the verdict was **submitted to GitHub at 16:02:33** (CHANGES_REQUESTED, review
`5923114983` — 1 new medium + 10 lows); the post-script applied the PR labels at
16:02:39–42; the health check recorded `run_health=1.00 (pass)`, 61 tool calls, 0
unanswered. The only failure was the final bookkeeping step: posting the agent-status
comment requires minting a short-lived status token from fullsend's mint service, and
that call timed out — *"Failed to post completion status: minting fresh client:
minting status token: calling mint service: context deadline exceeded"* (16:02:57).
Unable to confirm a clean completion, the harness posted **"🤖 Review · ❌ Terminated."**

Nothing was lost. The submitted verdict auto-triggered fix iteration 3 (16:04–16:10),
which fixed the new medium finding; the loop never paused. The GitHub Actions job is
green — the workflow wrapper exited 0 — so "Terminated" lives entirely in fullsend's
status layer, invisible to the Actions UI.

Why it matters: F2 is a silent setup failure — no work happens, no signal fires. F19 is
the inversion — **all the work happens and is delivered, and the status reports
failure.** The status comment is the signal a human uses to decide whether to
intervene; reading "Terminated," the natural reactions — re-trigger the review, or
post a corrective comment — collide with a fix round that is actually running (a
self-inflicted F14). Both directions of the status signal are now observed
unreliable. (The logs also show the run absorbing provider flakiness mid-flight —
"persona dispatch failed due to vertex," worked around with plain sub-agent calls,
9 tool errors, health still 1.00 — which the status layer collapses into the same
"Terminated" a hard kill would produce.)

*Remedies:* decouple the status comment from the verdict (post "success, status
degraded" when the result was validated and submitted but the mint failed); retry the
mint with backoff; or distinguish "agent terminated" from "status handshake failed"
in the status vocabulary.

**F20 — The verification gap is symmetric: human-driven fixes red CI too, and vacuous
tests hide it (medium; the mirror of F11/F15).**

*Case: the day-4/5 close-out — the human-directed fix batch on PRs #21/#23/#24,
2026-11-16 20:25 through 2026-11-17 14:11 UTC.*

The evaluation's core blind-push narrative (F11/F15: agents push code they cannot
verify) has a mirror image that this close-out demonstrated on the human side. The
fix batch was verified the way the humans actually verify: a full local `swift test`,
189/189 green. CI red on **both** attempts (~10 failures in suites the batch never
touched), and the diagnosis once again required reading CI step output that no agent
consumes — the same human-is-the-channel gap as F15, with the human's own agent
(here, the coding assistant driving the fix) as the blind party.

Two mechanisms, both environmental-determinism gaps between "my machine" and "the
runner":

1. **A cleanup defer deleted the shared temp directory.** The human agent's new test
   scoped its scratch folder directly under `$TMPDIR` and its cleanup removed the
   temp *root*, wiping every concurrently running test's scratch state. Locally
   invisible (fast machine, different interleaving, `try?` swallowing the partial
   failure); on GitHub's loaded runners it reproducibly killed whichever tests were
   mid-flight — while identical-shape tests passed in the same run, and the same
   commit stayed green locally. Three CI failures, one off-by-one-directory.
2. **Wall-clock deadlines vs. runner stretch.** The surviving failures were 2-second
   polling deadlines (and one 2-second launch-window classification) losing to a
   ~5x main-actor stretch on a loaded runner. A control rerun of the pre-batch head
   stayed green, so the trigger (the batch's +5 tests vs. runner-pool variance)
   stays ambiguous — the fixes (deadline headroom, a deterministic clock) are right
   regardless.

And the day produced **two independent instances of the vacuous-test trap** — tests
that pass without exercising what they claim:

- `JSONEncoder` escapes `/` as `\/`, so string-tampering a persisted JSON path
  without escaping both paths **silently no-ops** — two of PR B's new tests passed
  while proving nothing. Caught only because a third test (the one discriminating
  case) failed.
- PR B's legacy-layout test used the one repo-name shape (dashed) that satisfied the
  (wrong) delete guard, so it passed against the defect it existed to catch. Caught
  by the **review agent**, which recomputed the layout the base code actually
  generated from git history and flagged it high-severity — a real regression in the
  human's fix, found by the bot, missed by the human's test.

Why it matters: the difference between agent-driven and human-driven fixes is not
who verifies — both verify the same way (run the suite where they can) and both are
blind to the same environmental skew. The difference is *who catches the residue*:
here the loop's endgame earned its keep, with the reviewer catching a high-severity
regression the author's own test missed, and correctly recomputing true test counts
from the tree when the author's PR body misstated them. The general lessons are
stack-independent: cleanup scope must be exactly as narrow as setup scope; tests
that manipulate fixtures as text must be validated against the encoded form; and
every "it passes locally" carries the runner-skew caveat in both directions.

*Remedies:* for fullsend — nothing new; this is evidence that the CI→agent log
channel (F15's remedy) would have helped the human's agent exactly as it would help
the fix bot. For the repo — the two test-infra fixes landed (`584c51a`, `6a64ec5`);
fixture helpers that own both setup and cleanup scope would prevent recurrence.


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

*(Updated 2026-11-17 ~14:30 UTC — evaluation closed out.)*

- **PR #3 merged** (2026-11-12 ~17:15 UTC, by the human). Final head merged: `b7bdd56`.
  The loop terminated at its iteration cap: 7 review rounds, 6 fix rounds, 1 compile
  verification by the human.
- **PR #9 merged** (2026-11-12 22:57 UTC) — the auto-coded exit-127 fix, after its own
  loop run (merge-conflict resolution, the F1 per-run-instruction extension). Issue #6
  closed by the merge. Retro auto-fired (observation #3).
- **PR #12 merged** (2026-11-12 22:58 UTC) — the CI least-privilege fix. Retro
  auto-fired (observation #4), correctly reconstructing the F13 chain in its write-up.
- **CI is live on main** (PR #11, `a76376c`): `swift build` + `swift test` on macos-26,
  every PR and push. Issue #8 closed.
- **PR #14 merged** (2026-11-13 18:16 UTC, by the human, after the local smoke test) —
  `6f2d366`. Issue #4 auto-closed. The loop had converged at iteration 5 (CI green on
  `a7b68a9`, no high/medium findings); the 25 leftover lows are archived as issue #16.
  Retro auto-fired (observation #5) → issue #18 (see below).
- **PR #15 merged** (2026-11-13 ~17:29 UTC) — this document's F14–F17 batch; `main` at
  `88b2ae4` before the PR #14 merge.
- **PR #19 merged** (2026-11-16 13:46 UTC, by the human — the merge supplied the
  protected-path sign-off) — `90e4ef6`. Issue #18 auto-closed. The AGENTS.md
  review-finding policy is live on main and passed its first test; the known
  residual defect is the broken `#1760` autolink (AGENTS.md:99, TASKS.md:148),
  unfixed and unarchived (F18 day-4 capstone).
- **PR #22 merged** (2026-11-16 16:11 UTC) — the durable-deferral policy (objective-
  defect exception + append-to-#16 executor). Issue #20 auto-closed.
- **PR #23 merged** (2026-11-17 14:09 UTC, human-directed) — `1d19676`. The real
  defects from issue #16's archive: percent-decoded-slug crash, flattened unit
  directory, shape-checked delete guard (with the review-caught legacy-layout
  correction), unreadable-records rotation, withheld-persistence recovery, published
  save failures, typed git errors. The nits stay archived in #16.
- **PR #24 merged** (2026-11-17 14:10 UTC, human-directed) — `9034596`. **Issue #13
  auto-closed.** Deterministic Xcode selection with a Swift ≥ 6.2 gate,
  `persist-credentials: false`, the AGENTS.md CI-verification sentence, TASKS.md
  entry.
- **PR #21 merged** (2026-11-17 14:11 UTC, human-directed, last) — `c7a0ce8`. **Issue
  #17 auto-closed.** The browser-tabs feature (in-app tabs nested under review
  units) plus the close-out's 7 real deferred-low fixes, the CI-infra fixes (F20's
  remedies), and the external-opener seam forwarding. Final review round:
  CHANGES_REQUESTED with **low-severity findings only**; the fix loop had been
  cap-blocked since day 4 (8 iterations attempted vs. the 5 bot cap) — merged on
  human authority under the policy's stopping rule (no high/medium findings remain).
  The residual lows (29 across the last rounds) live in the PR's sticky review
  comment, unarchived — the same F18 burial the policy was written to prevent; the
  append-to-#16 step has still never been executed by a fix agent on this repo.
- **Issue #16 open, deliberately dormant** — the 25-low archive. Kept inert by canceling
  its triage run at the gate; standing rules: never edit the body, never add
  `ready-for-triage` (see the F18 case study). Still *incomplete*: the 3 lows deferred
  on PR #19 and the 29 on PR #21 never landed in it (F18/F20 residue).
- **Repo surface after cleanup:** no open PRs; only `main` remains locally and
  remotely (ten stale merged branches deleted); the five test worktrees removed.
  **199 tests across 22 suites on main (62/17/120), build and tests verified green
  after the merges.** Untracked local artifacts remain: `.fullsend/config.yaml.orig`
  and `config_options.md` (recommendation-7 working material).
- **Evaluation closed 2026-11-17** — 5 days, 24 PRs, 20 issues, every agent on
  GLM 5.3 (effort high) via EnMaaS, all defaults on throughout. Total observed agent
  spend ≈ $25–30 (reviews dominate: $1.29–3.02 per round; fixes $0.20–0.23; triage
  $0.07–0.12; retro ~$0.60).
- Zombie run 43095470483 still queued (harmless).

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
