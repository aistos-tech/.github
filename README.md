# aistos-tech/.github

Organisation-wide defaults and shared CI for Aistos repositories.

## What is automatic, and what is not

This distinction decides what belongs here.

| | Applies | Needs a file in each repo |
|---|---|---|
| **Community-health files** — PR template, issue templates, `CONTRIBUTING`, `SECURITY` | automatically to every repo that lacks its own | ❌ no |
| **Reusable workflows** | only when called | ✅ **yes** |

Reusable workflows are **pull-based**: this repo cannot make another repo run CI. Each repository
commits a small caller. What lives here is the *body*, so changing a check changes it everywhere at
once — the per-repo file is four lines and does not change again.

## Callers

```yaml
# .github/workflows/guards.yml, in any repository
name: Guards
on:
  pull_request:
  push:
    branches: [main]

jobs:
  secrets:
    uses: aistos-tech/.github/.github/workflows/gitleaks.yml@main
  commits:
    uses: aistos-tech/.github/.github/workflows/commitlint.yml@main
```

Both work with no configuration. A repo with a `.gitleaks.toml` or a `commitlint.config.js` has it
picked up; a repo without gets the shared default, so a repository with no JS toolchain still gets
its commit messages checked.

## What is deliberately NOT here

**A shared lint/test workflow.** The stacks do not converge: a TypeScript monorepo on turbo, a
VS Code extension, and two shell repositories share no build. `debt-collection` alone runs 11
workflows and 2,000 lines of CI with integration databases, Inngest and coverage merging on paid
runners — nothing in it is extractable, and a lowest-common-denominator `ci.yml` would fit none of
them.

What generalises is what is about **git** rather than about the stack: secrets and commit messages.
That is the line this repo holds. Pushing past it produces a workflow every repo overrides.

## Pinning

Callers use `@main` above for legibility. Pin to a SHA where a check must not change under a repo
without a review — `uses: aistos-tech/.github/.github/workflows/gitleaks.yml@<sha>`.
