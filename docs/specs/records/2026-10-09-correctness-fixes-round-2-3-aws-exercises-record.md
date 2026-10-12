# Record: Correctness fixes, round 2, part 3 — AWS exercises 13–18

What happened to [2026-10-09-correctness-fixes-round-2-3-aws-exercises](../2026-10-09-correctness-fixes-round-2-3-aws-exercises.md) after it was written. The spec is the plan; this file is its history, and nothing here is part of the plan. Sections appear as they're needed, in this order; leave out any that have nothing in them yet.

## Verification

- 2026-10-09: spec-verifier, 38 of 48 claims confirmed. Plan holds: yes.
- Verifier round 2 ran on 2026-10-09: after the cold review, re-checking W1, W2, W3, W4 and spike question 3. 14 of 20 claims confirmed. Plan holds: no, because W4's Step 15 `awk` couldn't match once W2 adds `--ignore-not-found`. Fixed after the round, and noted in Open questions.

## Cold review

Reviewed on 2026-10-09 by cold-reviewer. Saved unchanged; what was folded in is logged under Changes since the review.

| # | Kind | Where | Finding | Affects | Evidence | What would settle it |
|---|---|---|---|---|---|---|
| 1 | ASSUMPTION | W4 Step 10 policy condition; Spike 2; Design "Scoped writes" | The new IAM condition needs the ASG to carry `k8s.io/cluster-autoscaler/<cluster>=owned`. W4 rests on Step 11's `create-or-update-tags` to guarantee that, but Step 11's ASG lookup was not checked here. W5 row 18 says Step 11 stays but now describes the tags as already EKS-managed. The spec treats the Step 11 tag as the guarantee, yet the live check is deferred to a spike. If Step 11's filter returns an empty or multi-name `ASG_NAME`, the tagging step fails and every autoscaler write is denied. Step 13 (scale-up) would then show `AccessDenied` for a reason the spec never sees until the run. | correctness | `exercises/18-autoscaling/README.md:410-422`; `eks/modules/node_group/node_group.tf:91-94` | Round-2 EKS run (the spec already lists this as Spike 2) |
| 2 | GAP | W4 Step 15, `desiredSize=2` | The reset value is hard-coded to the variable default (`node_desired_count`, default 2). A learner who set `node_desired_count` in tfvars gets a different size than they started with, and the spec doesn't say to read the value from Terraform. The autoscaler's discovery tags are on every node group, so a GPU group is also discoverable. The W4 reset covers only `general`. | requirement: "Afterwards, a learner can run each exercise verbatim" | `eks/variables.tf:83-87`; `eks/modules/node_group/node_group.tf:91-94`; `eks/main.tf:34,51` | Decide: read the desired size from `terraform output`/tfvars, or state the assumption of default tfvars |
| 3 | COLD-READ | W1, W2 and W4 "Done when" (offline checks) | Several offline checks give no invocation. "With the AWS CLI's bundled `jmespath`" has no command or Python path. "`kubectl label --local … -o jsonpath`" does not test the `custom-columns` expression it stands in for, and the spec concedes it only tests "the field paths". "A draft of both policies passes in both shells" cites a draft that isn't in the spec. A cold reader can't reproduce these without the author. | requirement: "a cold reader has to be able to build it" | `docs/specs/2026-10-09-correctness-fixes-round-2-3-aws-exercises.md:111,142-143,184` | Give the exact commands, or move those checks to the EKS run |
| 4 | GAP | W2 "running 18's Prerequisites and clean-up twice … prints no `already exists`" | The check only looks for `already exists`. A second clean-up run still errors on the autoscaler delete, `aws iam detach-role-policy` and `delete-role` (NoSuchEntity), and `vpa-down.sh`. W2 puts `--ignore-not-found` on three lines only, and the Goal says each exercise runs verbatim. Running Step 10 twice also hits `EntityAlreadyExists`, which is the same phrase the check is meant to catch. | neither: the Done-when as written still passes; the second-run errors are NotFound, not `already exists` | `exercises/18-autoscaling/README.md:526-541` | Run clean-up twice |
| 5 | ASSUMPTION | W2 "18 VPA install", branch `vpa-release-1.8` | The spec pins a VPA branch but never checks it against the cluster's Kubernetes version (`kubernetes_version` default, 1.36). Whether `vpa-up.sh` on that branch works unchanged on that cluster is not stated. `[ -d /tmp/autoscaler ] \|\|` also keeps a stale default-branch clone left from an earlier run, and `git grep` can't detect that. The `Recreate`/`minReplicas` behaviour in W3 depends on 1.8 being installed. | requirement: "exercise 18 … run verbatim" | `exercises/18-autoscaling/README.md:95-96`; `eks/variables.tf:13` | Round-2 EKS run |
| 6 | ASSUMPTION | W3 Step 8: "`minReplicas: 1`" and "the Deployment has one replica" | Once the HPA is deleted at the start of Step 8, the Deployment keeps the replica count the HPA last set, not necessarily 1. The reasoning that `minReplicas: 1` is needed rests on a single replica, which is no longer guaranteed after Steps 3 and 5 scale it up. The Done-when only checks for an eviction event. | neither: it works either way, and only the explanation changes | `exercises/18-autoscaling/manifests/hpa.yaml:12-13`; `exercises/18-autoscaling/README.md:166-190` | Reading settles the mechanism; the run settles the timing |

Counts: 6 findings - 1 correctness, 3 requirement, 2 neither (rows 4 and 6; rows 2, 3 and 5 are requirement, row 1 is correctness)
Neither: 4, 6
Cold read: no - the first place I had to stop was the "Done when" offline checks ("with the AWS CLI's bundled `jmespath`"). Before that, W4 had a claim, "A draft of both policies passes in both shells", that points to nothing in the spec.
Needs a run: 1, 5, 6

Everything else I checked held up. Line references match HEAD, which is the `read-at` commit `5119a98`. All 20 W5 grep phrases match the exercise files before the change. `least-waste` is the CA 1.36.1 default (`config/flags/flags.go:147`), and `vpa-release-1.8` exists upstream. The route-table names follow `availability_zones` (`eks/modules/vpc/routes.tf:37`).

## Changes since the review

- Not reviewed: W4 adds a Step 11 check that stops on an empty or multiple `ASG_NAME` and confirms the `owned` tag, from cold review row 1, on 2026-10-09.
- Not reviewed: W4's Step 15 restores the desired size Step 10 saved, and zeroes a `gpu` group, with its Done when changed to match, from cold review row 2, on 2026-10-09.
- Not reviewed: W1's and W2's offline JMESPath and custom-columns checks move to the round-2 EKS run, and W4 drops the "draft" sentence, from cold review row 3, on 2026-10-09.
- Not reviewed: W2 makes exercise 18's clean-up safe to run twice, and its Done when also rejects `NoSuchEntity`, from cold review row 4, on 2026-10-09.
- Not reviewed: W2's VPA guard replaces a clone of another branch, and spike question 3 checks VPA 1.8 on 1.36, from cold review row 5, on 2026-10-09.
- Not reviewed: W3 explains `minReplicas: 1` against the HPA's last replica count, from cold review row 6, on 2026-10-09.
- Not reviewed: W4's Step 15 `awk` matches the autoscaler's `sed` line instead of a line ending in `kubectl delete -f -`, from verifier round 2, on 2026-10-09.
- Not reviewed: W5's Done when says what the grep prints before and after the change, and W1's count check prints `<path>:<n>`, from verifier round 2, on 2026-10-09.
- Not reviewed: W1 cites the per-zone subnets and route tables that make the first-AZ lookup order-proof, and W4 cites `eks/main.tf:46-51` for GPU groups, from verifier round 2, on 2026-10-09.
