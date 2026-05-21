# AGENTS.md

Nix flake providing composable wrappers for agentic CLI clients (Crush, Aider,
GitHub Copilot CLI). Library code lives in `lib/default.nix`; the example
wirings used by `packages` and `checks` live in `examples/basic.nix`.

## Commands

- `nix build .#skills` — build the example composed skill directory.
- `nix build .#crush-pr-assistant` (also `aider-pr-assistant`,
  `copilot-pr-assistant`) — build a wrapper binary.
- `nix run .#<wrapper-name>` — execute a wrapper. `default` is
  `crush-pr-assistant`.
- `nix flake check` — runs both `checks`: `rendered-skills` (validates
  rendered `SKILL.md` shape) and `wrapper-overlay` (executes a synthetic
  `fake-agent-wrapper` against a fabricated `$HOME`/`$XDG_CONFIG_HOME` to
  verify the runtime overlay).
- `nix fmt` — formats with `nixpkgs-fmt` (the flake's `formatter`).

There is no test runner beyond `nix flake check`; prefer adding new
assertions to the existing `checks` outputs rather than introducing another
framework.

## Architecture

The whole library is a single `let`-bound recursive attrset `agentLib`
returned by `lib/default.nix`. Everything is plain Nix functions plus
`pkgs.runCommand` / `pkgs.writeShellApplication` derivations — no external
build tooling.

Core data types, each tagged via a `type` attribute:

- `agents.skill` (`mkSkill`) → directory `<name>/SKILL.md` with YAML
  frontmatter plus optional extra files. Carries `packages` that any
  wrapper composing it must include at runtime.
- `agents.agent` (`mkAgent`) → prompt + skills + MCPs. Also exposes
  `agent.asSkill`, an auto-generated skill named `agent-<normalized-name>`
  so clients that only understand skills can still load the agent profile.
- `agents.mcp` (`mkMcp`) → either a `package` or a raw `command`. Raw
  derivations are also accepted anywhere an MCP is expected (see
  `packagesOfMcp`).

Composition pipeline inside `mkWrapper`:

1. Collect direct skills + skills pulled in by agents + each agent's
   `asSkill`, dedup by name via `uniqueByName` (first wins).
2. `mkSkillDirectory` produces `$out/skills/<name>` symlinks pointing at
   each skill's `path`.
3. `runtimePackages` unions client package, extra packages, every skill's
   `packages`, every agent's `packages`, and MCP packages — these become
   `runtimeInputs` of the generated shell application, so anything a skill
   references via `${pkgs.foo}/bin/foo` is guaranteed to be on `PATH`.
4. The wrapper script builds a per-user overlay at
   `${AGENT_WRAPPER_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agent-flake}/<wrapper>-<uid>`,
   symlinks the user's real `$HOME` and `$XDG_CONFIG_HOME` into it (skipping
   `.agents` / `.config` / `agents`), then rebuilds
   `~/.agents/skills` and `$XDG_CONFIG_HOME/agents/skills` as a merged
   view where **Nix-managed skills shadow user skills** on name collisions
   (`compose_skill_dir` iterates sources in order and uses `ln -sfnT`, so
   later sources overwrite earlier links. The real user dir is passed first
   and the managed dir last — preserve that ordering when touching
   precedence).
5. `HOME` and `XDG_CONFIG_HOME` are repointed at the overlay; the original
   values are preserved as `AGENT_WRAPPER_REAL_HOME` /
   `AGENT_WRAPPER_REAL_XDG_CONFIG_HOME`. `XDG_CACHE_HOME`,
   `XDG_STATE_HOME`, and `XDG_DATA_HOME` intentionally stay pointing at the
   real user dirs so clients keep their caches/logins.

## Conventions and gotchas

- **Skill names** must match `[a-z0-9]([a-z0-9-]*[a-z0-9])?`, ≤64 chars, no
  `--`. `validSkillName` enforces this with `assert`; bad names fail
  evaluation, not build. Use `normalizeSkillName` (lowercases, maps `_`,
  ` `, `.` → `-`) when deriving names from agent names; this is how
  `agent.skillName` defaults to `agent-<normalized>`.
- **Descriptions** are required (non-empty) and capped at 1024 chars.
- **`packages` vs `extraPackages`** on `mkSkill`/`mkAgent`: both are
  concatenated into the skill's `packages` list — there's no semantic
  difference, `extraPackages` is just a conventional slot for
  `nixpkgs`-derived deps so a caller can override `packages` without
  losing them. Follow the existing style: put `pkgs.foo` deps in
  `extraPackages`.
- **Frontmatter is hand-rendered** in `renderSkillMarkdown` via
  `builtins.toJSON` (JSON is valid YAML for scalars). `tags` are *not*
  written as a top-level frontmatter field — they go under
  `metadata.agent-flake.tags` as a comma-joined string because tags are
  not in the Agent Skills spec. Don't "fix" this without updating
  `rendered-skills` check expectations.
- **`allowedTools`** accepts either a list (joined with spaces) or a
  pre-formatted string; omit when empty.
- **Skill `files`** keys must be validated by `validRelativePath`
  (no leading `/`, no `..` traversal). String values are wrapped via
  `pkgs.writeText`; derivations/paths are copied as-is.
- **MCPs**: `mkMcp` requires either `package` or `command`. When `package`
  is given without `command`, the command defaults to `lib.getExe package`
  — so the package must set `meta.mainProgram` or expose a single binary.
- **Interface helpers** (`interfaces.crush` / `aider` / `copilot`) pull
  their default package from `pkgs` by name (`crush`, `aider-chat`,
  `github-copilot-cli`). `crush` and `github-copilot-cli` are unfree and
  are allowed via the `config.allowUnfreePredicate` in `flake.nix` — when
  adding a new unfree client, extend that list.
- **Wrapper safety**: `reset_dir` refuses any path not under
  `$runtime_root`, and the script exits 70 if `runtime_root` is empty or
  `/`. Preserve these guards when editing the shell.
- **Env injection** via `extraEnv` goes through `renderEnvExports`, which
  throws on names not matching `[A-Za-z_][A-Za-z0-9_]*`. Values are passed
  through `lib.escapeShellArg`.
- **Importing from files**: `importSkill` / `importAgent` use `callNix`,
  which auto-injects `{ pkgs, agentLib }` when the file is a function. Use
  this pattern for new external skill files rather than hand-importing.

## Adding things

- New skill/agent: add to `examples/basic.nix` and reference from the
  wrapper `agents`/`skills` list. The wrapper auto-collects transitive
  packages — do not also re-list those packages on the wrapper.
- New client interface: add an entry under `interfaces` that calls
  `mkWrapper` with `client`, `package`, and `program` defaults. Mirror
  the existing crush/aider/copilot pattern.
- Verifying overlay behavior: extend the `wrapper-overlay` check in
  `flake.nix` — it already fabricates a fake `$HOME`/`$XDG_CONFIG_HOME`
  and runs a synthetic wrapper that asserts on the resulting layout.
