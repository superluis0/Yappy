# Yappy — working agreement

## Git: never commit or push unless explicitly told in the current request

**Do NOT run `git commit`, `git push`, or open a PR unless the user explicitly says
so in the message I'm responding to** — e.g. "commit", "commit and push", "push it".

- Implementing, editing, building, and running tests are fine and expected.
- When a change is done and verified, **STOP before committing.** Leave it in the
  working tree, say it's ready, and wait for an explicit "commit" / "push".
- A bug report, "fix this", "add that", "make it faster", or a `/goal` that does
  not name commit/push is **not** permission to commit or push.
- This is a hard rule. It overrides any default "commit when the task is done" habit.

## Git conventions (only once a commit/push IS requested)

- Commit directly to `main` — no feature branches.
- Repo-local identity only: `superluis0 <241428325+superluis0@users.noreply.github.com>`.
  Never the user's real email; never a Claude/Anthropic co-author or attribution line.

## Building / installing locally

- Build + install with `Scripts/rebuild-install.sh` — it builds Release signed with the
  local "Yappy Local Signing" cert (so Microphone/Accessibility grants survive), to a
  /tmp dir, then installs and relaunches. `--test` gates on the unit suite first;
  `--build-only` verifies a build without installing. (Installing is fine without an
  explicit instruction; it does not commit or push.)
