# Baikal MTS experiments and netdevice candidate

These GPL-2.0-only historical snapshots document the reviewed code behind
EXP-20261017-012 and EXP-20261017-013. They are not enabled by the kernel target or patch series.
No operational runner, private firmware, raw UART, capture or binary is included.

- `phy-handoff/`: the one-setting correction and status witness from EXP-20261017-012.
  Source SHA256 3b6af1127573a2f998093f591015b9b0a900968a1789f8f778ff860b0cb8ff98;
  accepted module SHA256 a83dc5264869f22ea1015b3bce23897fa43bebacff8d48c8da95ddf3a1064b78.
- `packet-proof/`: the separately retained, original-order packet proof
  from EXP-20261017-013. Original privately tested source SHA256
  `9c30dd1c8536617217b0f00e079da6d553fef4b74b21517e777a66246407173a`;
  accepted original module SHA256
  `076c68334ab6e6a46b79f88ad40a3ad34aaa09b012015da14c868dde05f6b14d`.
  The public source is a redacted derivative: the real peer MAC was replaced
  with locally administered example `02:50:53:58:00:02`. Its source SHA256 is
  `4cde8828a87450e2f297d3a6b996266cd58ef8b356d7a548a42beb751def95ec`.
- [`netdev/`](netdev/README.md): the historical single-open Linux network driver
  candidate, with one opening attempt and permanent retention after DMA
  publication. Its first DHCP and4MiB TCP transfer in each direction passed EXP-20261017-014;
  repeated/lifecycle acceptance remains pending.

See [the handoff finding](../../docs/BAIKAL-MTS-HANDOFF.md) for the tested
register contract, provenance, observations and acceptance limits. Each
Makefile checks the accepted 6.18.44 release/config; a rebuilt module is a
candidate until its source/config/symbol/compiler identity and hardware plan
are reviewed. Use the repository's OrbStack workflow on macOS ARM64 or native
Linux x86-64 tools; do not compile the Linux kernel directly on Darwin.

The PHY/packet snapshots encode a specific retained-module experiment: old override,
DMA extents, stopped baseline and PHY identity are deliberate guards. They
are not standalone boot modules, general recovery commands or loadable
replacements for the live retained modules. A new experiment needs its own
sealed runner, one-attempt guards, peer protocol and bounded UART session.
All published outcomes retain module code and every DMA allocation; no safe
unload, reuse or reset contract was established by the packet proof.

The current continuous implementation lives in `patches/6.18-baikal-mts2/`.
These historical modules are not substitutes for it.
The polling snapshot is an earlier candidate toward normal-network acceptance;
it is not a production driver or a lifecycle acceptance result. A future
production change belongs in a real MTS driver patch. Keep
host-only tools in `scripts/dev/` and generated Linux state in `src/`.
