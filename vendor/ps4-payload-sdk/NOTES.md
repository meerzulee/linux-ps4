# vendor/ps4-payload-sdk

Vendored snapshot of the Scene-Collective PS4 Payload SDK.

## Provenance

- **Upstream:** https://github.com/Scene-Collective/ps4-payload-sdk
- **Vendored commit:** `2847f1f3a7d73e36cac1fbd40803733ebae98e1d`
- **Upstream subject:** `Add 13.50 support`
- **Vendored on:** 2026-05-11
- **Vendored by:** Meerzulee (PS4 Linux port project)

## What's removed vs upstream

- `.git/`, `.gitignore`
- `Dockerfile`, `action.yml`, `entrypoint.sh` — CI / GitHub-Action scaffolding we don't use
- Build artifacts (none in upstream, but excluded as a guard)

Everything under `libPS4/` is verbatim from upstream.

## Why vendored

We need a stable, reproducible build of the SDK at a known revision to
produce `tools/orbis-kernel-dumper/orbis-kernel-dumper.bin`. The SDK
covers PS4 firmware 5.00 → 13.50 with `caseentry(1202, ...)` confirmed
in `libPS4/include/payload_utils.h:255`, which is what we need for our
12.02 console.

## Updating

To refresh against upstream:

```
rm -rf vendor/ps4-payload-sdk
git clone --depth 1 https://github.com/Scene-Collective/ps4-payload-sdk \
  vendor/ps4-payload-sdk
rm -rf vendor/ps4-payload-sdk/.git
# update Vendored commit hash above to the new HEAD
```

Verify `libPS4/include/payload_utils.h` still has `caseentry(1202, macro)`
on whatever line it ends up on, and that `libPS4/include/fw_defines.h`
retains `K1202_*` macros.

## License

The SDK is licensed under its own terms (see `LICENSE` if upstream
provides one). Per CONTRIBUTING.md and ORIGINAL_CONTRIBUTIONS.md in
this repo, we attribute Scene-Collective and respect their license.
