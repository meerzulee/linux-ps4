# PS4 kernel contributor instructions

## Scope and sources

- This repository owns the patch-based PS4 kernel, target configs, build
  containers, module archives and provenance. In the larger workspace its
  directory is `linux-ps4-kernel/`; the GitHub repository is
  `https://github.com/meerzulee/linux-ps4`.
- Use `targets/`, ordered `patches/<target>/series` and committed configs as
  the build inputs. Preserve upstream pins, authors and licenses.
- Obtain this repository from `https://github.com/meerzulee/linux-ps4.git`.
  The full workspace pins its development revision in the sibling
  `omarchy-ps4/manifests/development-sources.json`; follow that manifest when
  setting up another computer. The current development branch is
  `agent/document-baikal-capabilities`.
- Let `build.sh` download upstream Linux from the selected target's
  `BASE_REPO`/`BASE_REF` and verify `BASE_COMMIT`. Do not ask the operator to
  transfer a generated `src/` tree when the pinned source is downloadable.
- `src/` is generated build state. The builder resets and cleans it; save any
  intended source edit as a patch before rebuilding.
- Consult `STATUS.md`, `docs/CAPABILITY-TESTS.md` and the sibling Omarchy
  experiment ledger before making support claims. Historical `CLAUDE.md`
  checkpoints do not supersede current target pins or accepted evidence.

## Host tools

- Follow `README.md` for macOS ARM64 and Arch Linux x86-64 setup.
- On Apple Silicon, use `scripts/build-kernel-orbstack`. It cross-compiles the
  PS4 x86-64 target inside an ARM64 Linux container. Do not run the native
  Linux build directly on Darwin.
- On x86-64 Linux, use native `make TARGET=6.18-baikal`; no container is
  required. Do not change the target architecture to match an ARM Mac.
- Use OrbStack exclusively whenever containers or Linux VMs are needed.
  Before Docker work, verify `orb status` reports `Running` and
  `docker context show` reports `orbstack`.
- Do not start Docker Desktop, Colima, Lima, Homebrew PostgreSQL or another
  local container/VM runtime. Do not remove runtime guards to run elsewhere.
- Preserve known-good outputs and record compiler/config/module identity.
  A native Arch build is a candidate, not automatically byte-identical to a
  pinned release build.

## Hardware boundary

- Building, source inspection and local host tests do not need a PS4 UART
  session. Console actions require explicit task authority.
- For a consequential hardware experiment, state one objective, stable
  `EXP-YYYYMMDD-NNN` ID, expected evidence, timeout and safe rollback; confirm
  continuous UART and open one bounded session before the first action.
- Keep one experiment active, vary one diagnostic input and close/conclude it
  before changing branches of investigation. A reconnect or logger restart
  invalidates continuity; only `completed` sessions support acceptance.
- In the full workspace, follow
  `../omarchy-ps4/docs/DEVELOPMENT-MODE.md` and record conclusions in
  `../omarchy-ps4/experiments/SESSIONS.md`. In a standalone clone, obtain that
  workflow before operating the console.
- Never send a payload, reboot/power off the console, write its internal boot
  files, or format/overwrite media just because a build completed. Do not
  mount, repair or modify the PS4 internal disk.
- Three repetitions of a failure without new evidence end that path. A
  single successful boot does not satisfy repeated acceptance gates.

## Git and handoff

- Preserve existing local work. Inspect the current branch and live remote
  state before switching devices; development may be outside `master`.
- Pushing, publishing releases and rewriting history require explicit task
  authority. Keep private raw logs and firmware-derived inputs out of new
  public commits.
- Use repository-relative paths. Keep sibling names stable in the full
  workspace. Include full raw web URLs and absolute local artifact paths in
  operational handoffs; add a pasteable macOS `open` command when useful.
