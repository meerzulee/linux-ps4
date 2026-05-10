# v56 result — bisect: disable v54 source-only training

**Series edit:** comment out `0028-amdgpu-ps4-source-only-dp-training-pulse.patch`
**Boot log:** `checkpoint/uart-logs/2026-05-10_1836-v56-revert-source-train.log`
**Result:** v54 INNOCENT — chunk A second cycle still shows `0x60f8=0x0f` and ~607ms elapsed, identical to v55.

First clean falsification in the bisect chain. Confirmed the source-only DP training pulse from v54 was not the cause of the 2.97s bridge hang. Pivoted to bisecting v53 next.

Series file unchanged otherwise; bzImage md5 `2177bfd72a497dc83e7235681ffe9cc5`.
