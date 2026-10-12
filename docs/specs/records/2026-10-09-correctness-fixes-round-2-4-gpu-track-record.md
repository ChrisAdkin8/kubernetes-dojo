# Record: Correctness fixes, round 2, part 4 — GPU track

What happened to [2026-10-09-correctness-fixes-round-2-4-gpu-track](../2026-10-09-correctness-fixes-round-2-4-gpu-track.md) after it was written. The spec is the plan; this file is its history, and nothing here is part of the plan. Sections appear as they're needed, in this order; leave out any that have nothing in them yet.

## Verification

- 2026-10-09: spec-verifier, 26 of 35 claims confirmed. Plan holds: no, because W2's answer 4 labelled `$GPU_NODE`, which exercise 05 never defines.
- Verifier round 2 ran on 2026-10-09: after verification, re-checking W2 and W5. 31 of 40 claims confirmed. Plan holds: yes.

## Cold review

Reviewed on 2026-10-09 by cold-reviewer. Saved unchanged; what was folded in is logged under Changes since the review.

| # | Kind | Where | Finding | Affects | Evidence | What would settle it |
|---|---|---|---|---|---|---|
| 1 | WRONG | W4 "Answer 5 (`:185`): the second replica stays Pending on one g4dn.xlarge"; Design "which can be skipped when going straight on to the next exercise" | The new Answer 5 is true only with one GPU node. Exercise 03 runs `up 2`. If 03's `down` is skipped, 04's `up 1` is a no-op because it only raises the size, so two nodes stay up. Then the second replica schedules and the stated fact is false. The "one Ready GPU node" check in W1 holds only if 03's `down` ran. The same skip leaves two nodes for 05 and 07. | correctness: it breaks the Goal's "nothing in the track is false", and the one-node assumption behind W4's Answer 5 | spec Design lines 108-117. `up` is "only if lower", so it never scales down. `model-server-deployment.yaml:76-81` requests a whole GPU. | Make `up N` set the size to exactly N, or make 03's `down` mandatory. Alternatively, word Answer 5 as "on one node". |
| 2 | GAP | W2 Step 2 `port-forward svc/dcgm-exporter 9400:9400` | `svc/` forwards to one arbitrary pod. When 03's two nodes are still up (see #1), the DaemonSet has a pod on each. The forward can land on the idle node, so Step 2 or the Step 5 poll reads ~0 and the "50 or more" check flakes. | correctness: W2's Done when run can fail | W2 Change; `up 2` in Design; `kubectl port-forward svc` picks a single backing pod | Same fix as #1, or select by `pod/$DCGM_POD` on the node running `gpu-load`. |
| 3 | GAP | W3 "set `enable_efs = true` … `reclaimPolicy: Delete`" | `reclaimPolicy` on an existing StorageClass is immutable. A learner who applied the old `Retain` class gets a `Forbidden` error on `kubectl apply`. W3's Step 1 pipe doesn't delete or recreate the class, and the clean-up never deletes the StorageClass. | correctness: a re-run, or a cluster that ran the earlier version, fails at Step 1 | `efs-storageclass.yaml:13`. Part 1 line 209 itself tests an applied `Retain` class. | Add `kubectl delete sc <name> --ignore-not-found` to the Prerequisites, or to the clean-up. Needs a run to confirm. |
| 4 | GAP | W3 Clean-up "wait until no PV names `shared-dataset`" | No command is given, so a cold reader has to invent one. `kubectl wait --for=delete pv/<name>` needs the PV name, which is dynamic (`pvc-<uid>`). This wait gates `enable_efs=false`, and a premature apply fails or leaks. | requirement: "Teardown … nothing billing" (the clean-up has to work as written) | W3 Change lines 165, 237 | Give the exact command, for example `kubectl get pv -o jsonpath` filtered on `claimRef.name`, in a loop with a bound. |
| 5 | GAP | W2 Prerequisites "add `--version 92.2.0` and the allowlist" | The install sits under "If not present:". A learner with a Prometheus already installed skips it and has neither the pin nor `kube-state-metrics` `metricLabelsAllowlist`. Answer 4 then can't match, and `release: kube-prometheus` may not hold. | requirement: "exercise 05 shows real metrics" | `05-gpu-monitoring/README.md:49-61`, the `kubectl get svc … \| grep prometheus` conditional | Say to uninstall or upgrade an existing stack, or to require the name `kube-prometheus`. |
| 6 | GAP | W1 Done when `git grep 'until \['` prints nothing, against W2's "polls every 10 s for 3 minutes" | W1's grep covers all `gpu-ml/*.md`, including 05. If W2's poll loop is written as `until [ …`, W1's check goes red. The spec doesn't say which loop form to use. | neither: a check-ordering trap, caught on first run | W1 Done when line 131; W2 Change line 145 | Name the loop form, or narrow the grep. |
| 7 | ASSUMPTION | W2 Step 1 `serviceMonitor.scrapeTimeout`, `extraEnv` | The key names and the 25s default come from `helm show values` of 4.8.3. The spec's own Done when line 150 checks the rendering, so this is covered. The claim that `scrapeTimeout` is a values key is not checked in the repo. | neither: covered by the helm template check | Background line 57 | Run `helm template`. |
| 8 | ASSUMPTION | Spike 1, W3 `Delete` | The spec assumes the EFS CSI driver deletes the access point on PVC delete, and that the add-on role holds `DeleteAccessPoint`. The role comes from part 1 W5 and is not checked here. The spec marks the first as a spike with a fallback, but the fallback isn't written into the clean-up. | requirement: "Teardown … leaves nothing billing" | Part 1 lines 235-246 not shown to grant it; spec line 237 | A run (see Needs a run). |
| 9 | COLD-READ | Design "`up [N]`… raises … only if lower" | The script's mechanism isn't specified: how it reads the current desired size, which `aws` call it uses, and whether it needs `AWS_REGION` exported. A stub test `PATH` setup is given without the stubs' expected calls. | neither: a competent reader can infer it | Design lines 108-113 | None needed. |
| 10 | COST | W1 "all seven exercise READMEs" | The `../../gpu-nodes.sh` path assumes the learner's cwd is the exercise directory. No exercise README says `cd`. The new script also needs its executable bit and a mention in the `gpu-ml/README.md` prerequisites. | neither: relative `manifests/` paths already imply the cwd | `git grep 'cd '` over the exercises finds nothing; `manifests/` paths are used | None needed. |

Counts: 10 findings - 3 correctness, 2 requirement, 5 neither
Neither: 6, 7, 9, 10 (and 8 is graded requirement)
Cold read: no - first place I had to stop was Design/W1: `up` never scales down, so the one-node assumptions in W4 and W2 depend on `down` having run.
Needs a run: 3, 7, 8

## Changes since the review

- Not reviewed: the Design's `gpu-nodes.sh up N` sets the group to exactly N, lowering it too, and polls for exactly N nodes, from cold review row 1, on 2026-10-09.
- Not reviewed: W2 says the exporter Service has one pod, given one GPU node and the exporter's `nodeSelector`, from cold review row 2, on 2026-10-09.
- Not reviewed: W3 deletes the `efs-ml` StorageClass before Step 1 and in the clean-up, because `reclaimPolicy` can't change in place, from cold review row 3, on 2026-10-09.
- Not reviewed: W3's clean-up gives a bounded PV wait loop, from cold review row 4, on 2026-10-09.
- Not reviewed: W2's Prerequisites drop the "If not present" check, so the pinned stack always installs or upgrades, from cold review row 5, on 2026-10-09.
- Not reviewed: W2's poll is a `for` loop, so W1's `until [` grep stays clean, from cold review row 6, on 2026-10-09.
- Not reviewed: Background cites dcgm-exporter's `values.yaml` lines for `scrapeTimeout` and `extraEnv`, from cold review row 7, on 2026-10-09.
- Not reviewed: W3's clean-up deletes any leftover access points by hand, and spike 1 notes the role's `DeleteAccessPoint` need, from cold review row 8, on 2026-10-09.
- Not reviewed: the Design spells out the script's `aws` and `kubectl` calls, and W1's stub test says what each stub does, from cold review row 9, on 2026-10-09.
- Not reviewed: the Design says the script is executable, listed in the GPU README's prerequisites and run from the exercise directory, from cold review row 10, on 2026-10-09.
