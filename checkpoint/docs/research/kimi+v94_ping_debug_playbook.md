# v94 — Ping-failure debug playbook (post-v93 netdev bring-up)

**kimi-k2.6, 2026-05-13**

Run these in order. Do not skip steps.

## 1. PS4 carrier ON?
**Command** (on PS4): `ip link show mts0`
**Pass**: `state UP` + `<NO-CARRIER>` absent.  
**Fail**: `NO-CARRIER` → MAC link bit dropped after `ndo_open`; review `mts_open` engine start / IRQ enable.

## 2. Host link partner detected?
**Command** (on host): `ip link show enp8s0f3u1`
**Pass**: `state UP` + `<LOWER_UP>`.  
**Fail**: `NO-CARRIER` on host → PS4 TX dead or PHY lost link; go to step 3.

## 3. PS4 TX counters increment?
**Command** (on PS4): `ip -s -s link show mts0`
**Pass**: `TX: packets` rises after `ping`.  
**Fail**: Stuck at 0 → `ndo_start_xmit` not called (queue stopped?) or descriptor ownership never flipped / TX engine not kicked.

## 4. Host RX counters increment?
**Command** (on host): `ip -s -s link show enp8s0f3u1`
**Pass**: `RX: packets` rises.  
**Fail**: Stuck at 0 with PS4 TX rising → wire-level TX failure (marginal signal) or host PHY RX squelch; check cable/different host NIC.

## 5. Host TX counters increment?
**Command** (on host): `ip -s -s link show enp8s0f3u1`
**Pass**: `TX: packets` rises after ping reply attempt.  
**Fail**: Stuck at 0 → host ARP incomplete (step 7) or host routing missing; not a PS4 problem.

## 6. PS4 RX counters increment?
**Command** (on PS4): `ip -s -s link show mts0`
**Pass**: `RX: packets` rises.  
**Fail**: Stuck at 0 with host TX rising → PS4 RX engine not started, descriptor ownership not set to MAC, or ISR/NAPI not scheduling.

## 7. ARP table state
**Command** (both sides): `ip neigh show`
**Pass**: Peer MAC shows `REACHABLE` or `STALE`.  
**Fail**: `INCOMPLETE` → request sent but no reply received; cross-check steps 3/4 vs 5/6. `FAILED` → no reply after retries.

## 8. PS4 routing table
**Command** (on PS4): `ip route show`
**Pass**: Route to host subnet exists (e.g. `192.168.1.0/24 dev mts0`).  
**Fail**: No route → `ip addr add` missing or wrong subnet; ping never reaches `ndo_start_xmit`.

## 9. MAC address validity
**Command** (on PS4): `ip link show mts0 | grep ether`
**Pass**: Valid unicast (first byte even), not `ff:ff:ff:ff:ff:ff`.  
**Fail**: Random MAC collides on LAN or is multicast → switch drops frames; generate new random MAC.

## 10. Firewall drop
**Command** (both sides): `nft list ruleset` or `iptables -L -n`
**Pass**: No `DROP` rules on `INPUT`/`FORWARD` for ICMP.  
**Fail**: Rules present → `nft flush ruleset` and re-test.

## Quick triage matrix

| PS4 TX | Host RX | Host TX | PS4 RX | Diagnosis |
|---|---|---|---|---|
| 0 | 0 | 0 | 0 | `mts0` not sending; check queue stopped / carrier off |
| ↑ | 0 | 0 | 0 | PS4 TX works electrically but host sees nothing; cable / PHY issue |
| ↑ | ↑ | 0 | 0 | Host not replying; check host ARP / routing / firewall |
| ↑ | ↑ | ↑ | 0 | Host replies but PS4 RX path broken; check NAPI / descriptor refill |
| ↑ | ↑ | ↑ | ↑ | Layer 3 issue; ARP table or firewall |
