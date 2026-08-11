# Publishing the PS4 kernel for Arch Linux

Snapshot date: 2026-08-10

## AUR versus a binary repository

The AUR hosts source build recipes, not a pacman binary repository. To publish
there, create a `PKGBUILD` and generated `.SRCINFO`, register an AUR account
and SSH key, and push the package Git repository. See Arch's
[AUR submission guidelines](https://wiki.archlinux.org/title/AUR_submission_guidelines).

The clean source package should build split packages such as:

- `linux-ps4-baikal`
- `linux-ps4-baikal-headers`

Pin the upstream kernel tag/commit and an immutable release tarball containing
the patch series and config. Use checksums; do not fetch moving branch heads.
A `-bin` AUR recipe may download a release artifact, but the AUR itself still
does not host that binary.

## Hosting prebuilt packages

For user-friendly installs, host a separate HTTPS pacman repository:

1. Build x86_64 `.pkg.tar.zst` kernel and header packages in a pinned Arch
   builder.
2. Sign packages with a dedicated repository GPG key.
3. Generate and sign the database with `repo-add --sign`.
4. Publish packages, database, signatures, and public key over HTTPS.
5. Provide a small `pacman.conf` stanza and documented key enrollment.
6. Retain at least one known-good version for rollback.

Arch documents the format in
[Custom local repository](https://wiki.archlinux.org/title/Pacman/Tips_and_tricks#Custom_local_repository)
and the signing model in
[Repo DB signing](https://wiki.archlinux.org/title/DeveloperWiki:Repo_DB_Signing).
GitHub Releases can host immutable artifacts initially; static object storage
or Pages is better once retention and bandwidth matter.

## Minimum release quality

- source tag and exact Linux base commit;
- transparent patch provenance;
- reproducible PKGBUILDs for kernel and matching headers;
- signed source and binary artifacts;
- config, manifest, checksums, and build logs;
- firmware and licensing audit;
- hardware test record for the exact Baikal revision;
- recovery instructions and package rollback;
- no proprietary firmware, Sony material, or per-console EAP key in packages.

This repository's raw `bzImage` and module archive are useful build artifacts,
but they are not yet an Arch package. A proper headers package, preset/initramfs
integration, package hooks, and hardware acceptance record are still required
before submitting it as a supported AUR package.
