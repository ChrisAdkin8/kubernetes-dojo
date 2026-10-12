# Record: Correctness fixes, round 2, part 1 — EKS platform

What happened to [2026-10-09-correctness-fixes-round-2-1-platform](../2026-10-09-correctness-fixes-round-2-1-platform.md) after it was written. The spec is the plan; this file is its history, and nothing here is part of the plan. Sections appear as they're needed, in this order; leave out any that have nothing in them yet.

## Verification

- 2026-10-09: spec-verifier, 36 of 47 claims confirmed. Plan holds: yes.
- Verifier round 2 ran on 2026-10-09: after the cold review, re-checking W1, W2, W3, W5 and the Design. 56 of 58 claims confirmed. Plan holds: yes.

## Cold review

Reviewed on 2026-10-09 by cold-reviewer. Saved unchanged; what was folded in is logged under Changes since the review.

| # | Kind | Where | Finding | Affects | Evidence | What would settle it |
|---|---|---|---|---|---|---|
| 1 | WRONG | W3 Change step 4: "no PV with `reclaimPolicy: Delete` remains" | `reclaimPolicy` is a StorageClass field. A PV's field is `spec.persistentVolumeReclaimPolicy`. A script written from the spec text, for example with `jsonpath={.spec.reclaimPolicy}`, matches nothing. The wait then returns at once, before the volumes are gone, and `destroy` can orphan EBS volumes. | requirement: "teardown leaves nothing billing" | Spec W3; `exercises/07-persistent-storage/manifests/storage-class.yaml:11` is the StorageClass-level field. | Name the PV field in the spec, and add a leftovers check that fails if the wait misfires. |
| 2 | GAP | Design step 6 (leftovers check), Spike 2, and the log group check | The spec makes the log group Terraform-managed, but EKS may recreate it during cluster deletion (Spike 2). The spec gives no step for that case. The September plan had a "delete it after destroy" step (September part 1:228) that this spec neither keeps nor drops. | requirement: "teardown leaves nothing billing" | Spec spike 2; `README.md:243` currently says the group never expires. | Add the fallback: if the leftovers check lists the group, run `aws logs delete-log-group` and record that. |
| 3 | GAP | W5 / Spike 3 / Design step 5 | Step 5 destroys with `enable_efs = true` after exercise 06. Exercise 06's class is `Retain`, so access points survive PVC deletion. W3's script only lists `Retain` PVs and doesn't delete them. Whether `DeleteFileSystem` and `destroy` then succeed is left to Spike 3. A part-1 EKS run could therefore fail at `destroy` or leave an EFS file system behind. | requirement: "teardown leaves nothing billing" | `gpu-ml/exercises/06-storage-for-ml/manifests/efs-storageclass.yaml:13` is `Retain`. Part 4 changes it to `Delete` only as an assumption (part 4:164). | A run, or a pre-destroy step that deletes the access points of the EFS PVs. |
| 4 | ASSUMPTION | W5 Change, IRSA role and add-on | The trust uses `StringLike` on `efs-csi-*` and a single `service_account_role_arn`. Whether the add-on applies that role to both the controller and node service accounts is not established. The spec marks the page's IRSA steps *(unverified)*. The EBS pattern it copies pins one exact service account (`eks/modules/eks_cluster/data.tf:27-49`). | requirement: "the stack can create the EFS storage that GPU exercise 06 needs" | Spec Background (EFS). | Round-2 run: the add-on is ACTIVE and part 4's PVC binds. This is already in Done when, but there is no fallback if it fails. |
| 5 | COLD-READ | W1 | The mock contents are not specified: which AWS data sources need values, the zone names, and the OIDC/TLS certificate values. W1's "8 passed" can't be reproduced from the listed cases. The five validations plus the three other cases give 8 only if the role-name check is one run. The counts (8, 3, 2, 3) and the "fails before with <error>" strings come from an "unrecorded scratch run" on Terraform 1.16.0. | requirement: "a cold reader has to be able to build it" | Spec Design ("assumption: an unrecorded scratch run"); W1 Done when. | Specify the mock values and list the runs one per line. |
| 6 | ASSUMPTION | W2 Done when: "fails with `Reference to undeclared local value`" | `region.tftest.hcl` also asserts `output.region` and uses `expect_failures`. Before the change, Terraform may report a different error first, such as an undeclared output or a different run failing. The quoted string may not be what the reader sees. | neither: the check still fails before and passes after, so only the quoted error text is at risk | W2 Tests / Done when. | A run (see Needs a run). |
| 7 | GAP | W2 Lookup | If a region has fewer than two opt-in-not-required zones, indexing the first two fails with an obscure error, and there is no precondition. | neither: affects only unusual regions | W2 Change. | Add a `precondition` on the data source. |
| 8 | STALE | W4 Docs / Design step 4 | The September "log-volume measurement" step set an end state ("finish with `aws logs delete-log-group`", September part 1 step 5) that contradicts a Terraform-managed log group. The spec points to September items 70-75 without saying that step 5 is superseded. | neither: the spec's own step 6 covers the destroy | `docs/specs/2026-09-14-p0-p1-correctness-fixes-1-platform.md:70-75` and `:228`. | Say that September step 5 is replaced by Design step 6. |
| 9 | COLD-READ | W5 `module.efs` inputs | The module's variables are not listed. It needs the cluster name, `vpc_id`, `vpc_cidr`, the private subnet IDs, and the OIDC ARN and URL. `module.eks_cluster` already outputs the last two (`eks/modules/eks_cluster/outputs.tf:27-36`) and the spec does not mention them. Using `depends_on` on a module also defers its data sources to apply time. | neither: the code can be worked out | Spec W5 Files. | List the module variables. |
| 10 | COLD-READ | Design, `tftest` shorthand | `tftest` is not a command. Done-when lines say `tftest -filter=…`. The README line W1 adds must spell out the whole command with its `env -u …` prefix. | neither | Spec Design. | None needed. |

Counts: 10 findings - 0 correctness, 3 requirement, 7 neither
Neither: 6, 7, 8, 9, 10 (plus 5, which is graded as a requirement)
Cold read: no - W1 is the first place I had to stop. It does not say what the mocks contain or how the 8 runs are counted.
Needs a run: 3, 4, 6

## Changes since the review

- Not reviewed: W3's wait checks a PV's `spec.persistentVolumeReclaimPolicy`, and the leftovers check's EBS query is named as its backstop, from cold review row 1, on 2026-10-09.
- Not reviewed: W3's destroy docs and Design step 6 delete the log group if EKS re-created it, from cold review row 2, on 2026-10-09.
- Not reviewed: `pre-destroy.sh` reads `region` and deletes the access points behind EFS PVs, with a `Retain`-class EKS check and W3's effort raised to 2.5 h, from cold review row 3, on 2026-10-09.
- Not reviewed: spike question 6 and a W5 fallback for the EFS add-on role reaching both service accounts, from cold review row 4, on 2026-10-09.
- Not reviewed: W1 lists its eight runs and the mock values, from cold review row 5, on 2026-10-09.
- Not reviewed: W2's and W5's before-change failures restated from a scratch run on 2026-10-09 (W5's `init` fails with `Unreadable module directory`, which blocks every test file until the module exists), from cold review row 6, on 2026-10-09.
- Not reviewed: W2's zone lookup gains a postcondition, a `min()` guard and a fourth test run (4 passed), from cold review row 7, on 2026-10-09.
- Not reviewed: Design step 4 says September's step 5 is replaced, from cold review row 8, on 2026-10-09.
- Not reviewed: W5 lists `module.efs`'s inputs and the `depends_on` deferral, from cold review row 9, on 2026-10-09.
- Not reviewed: W1's README line spells out the full test command, from cold review row 10, on 2026-10-09.
- Not reviewed: W5 says exercise 06 finds the file system through `efs_file_system_id` (part 4 W3), so it needs no `cluster` tag, from verifier round 2, on 2026-10-09.
- Not reviewed: the Design's EKS-run budget is for an eight-hour working day, and the GPU price is marked unverified, from verifier round 2, on 2026-10-09.
- Not reviewed: W3's guard-test prototype is marked as an assumption, from verifier round 2, on 2026-10-09.

## Spikes

- Question 1: Route: deferred.
- Question 2: Route: deferred.
- Question 3: Route: research.
- Question 4: Route: deferred.
- Question 5: Route: research.
- Question 6: Route: deferred.
