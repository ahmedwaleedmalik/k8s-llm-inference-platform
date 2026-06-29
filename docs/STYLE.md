# Docs style guide

Rules for writing (and for any agent drafting) docs in this repo. The goal is docs that read
like a person who ran the commands wrote them — because that's the actual fix for "AI slop,"
not synonym-swapping after the fact.

Vale (`.vale.ini`) enforces the mechanical rules in CI. This page covers the ones it can't.

## The one rule that matters

**Every claim cites a file, a flag, a number, or an observed output.** Slop is what gets written
when there's nothing concrete to say. If a sentence can't point at something real, it's padding —
cut it.

- Bad: "vLLM offers powerful, flexible serving with great performance."
- Good: "vLLM serves `/v1/chat/completions`; on an L4 at concurrency 8 the harness records
  TTFT p50 ≈ X ms (`docs/benchmarks.md`)."

## Grounding (kills hallucination + vagueness)

- Paste commands and output from a **real run**. Never invent a flag, a target, or a path.
- If you didn't verify it, say so explicitly ("untested on provider X") — don't imply coverage.
- Link the implementation: the file, the `values.yaml` key, the ADR. Don't describe from memory.

## Structure (kills the "sounds like ChatGPT" tell)

The tell is structural, not vocabulary: every section the same length, rule-of-three lists, an
intro that restates the heading, a conclusion that restates the intro.

- Don't open a section by echoing its title. Start with the thing.
- Vary length. Some steps are one line. Don't pad them to match.
- Drop the summary paragraph that restates what you just said.
- One page, one job (Diátaxis): a tutorial teaches, a runbook does a task, an ADR explains a
  decision, a reference lists facts. Mixed-mode pages are where the waffle lives.

## Banned words

Marketing adjectives and filler (`reject.txt` flags these): seamless, robust, powerful,
cutting-edge, leverage, utilize, delve, streamline, world-class, plethora, supercharge, unlock.
The fix is a concrete claim, not a synonym.

Also avoid: "it's worth noting", "in order to" (→ "to"), "in today's landscape", "dive in",
"at the end of the day", "simply"/"just" (it's rarely simple).

## Voice

- Active voice, present tense. "Argo reconciles the cluster," not "the cluster is reconciled."
- Second person for instructions ("you apply the root"), not "we" or passive.
- Terse over polite. No "Let's", no "Great!", no throat-clearing before the content.

## Before publishing

AI drafts, human cuts ~30%. The draft is the easy part; the cut is where it stops sounding
generated. Read it once and delete every sentence that doesn't carry a fact.
