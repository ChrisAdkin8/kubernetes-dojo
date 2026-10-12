# Record: Correctness fixes, round 2, part 2 — core exercises 01–12

What happened to [2026-10-09-correctness-fixes-round-2-2-core-exercises](../2026-10-09-correctness-fixes-round-2-2-core-exercises.md) after it was written. The spec is the plan; this file is its history, and nothing here is part of the plan. Sections appear as they're needed, in this order; leave out any that have nothing in them yet.

## Verification

- 2026-10-09: spec-verifier, 58 of 63 claims confirmed. Plan holds: yes.
- Verifier round 2 ran on 2026-10-09: after the cold review, re-checking W1, W2, W4, W5 and the Design. 40 of 55 claims confirmed. Plan holds: yes.

## Cold review

Reviewed on 2026-10-09 by cold-reviewer. Saved unchanged; what was folded in is logged under Changes since the review.

| # | Kind | Where | Finding | Affects | Evidence | What would settle it |
|---|---|---|---|---|---|---|
| 1 | GAP | W4 Done when, `grep` check (`does not enforce NetworkPolicies`) and the exercise 11 README text | W4 fixes the false claim about the VPC CNI in `deny-all.yaml:4-6`. It leaves `exercises/11-network-policies/README.md:28`, which says the VPC CNI "does **not** enforce NetworkPolicies unless…". The README's Step 3 and answer 2 also tell the learner to check for the add-on and for Calico or Cilium (`:150`). The spec's own point is that Terraform already turns enforcement on, so these are partly stale for this cluster. The grep can't catch line 28 because the README writes `does **not** enforce`. The Done-when therefore passes with the README text still unreconciled. The spec never says whether line 28 is true as written or needs a change. | requirement: "trust them" (the Goal, "teaches something false") | README:28 and :150; the pattern in W4's grep | Decide whether README:28 stays. If it changes, add it to W4's Change list and widen the grep. |
| 2 | COLD-READ | Design, "kind v0.33.0, the version commit `d27b56c` used"; every "On kind" check | The spec gives no kind cluster config, node count, or way to confirm that NetworkPolicy is enforced. W2's exercise 09 check says "single node", while the exercise 12 and 11 checks need a cluster that enforces policy. W4 refers to the September spec's "S1" without saying what it is. The cold reader has to find `d27b56c` and S1 to build the test cluster. | requirement: "a cold reader has to be able to build it" | W4 Done when; Design bullets | State the kind config, or link the file or section that defines it. |
| 3 | ASSUMPTION | W4 Change, `allow-dns-egress` with `to:` plus the label `k8s-app: kube-dns` | The tightened rule is committed to the manifest before spike 1 has run. The fallback ("the `namespaceSelector` alone") is described only in the spike, and W4's Done-when doesn't say which form is the deliverable. If spike 1 fails, the Done-when's "Round-2 EKS run: the same checks" fails against the shipped manifest. The Risks section admits this. | correctness (a possible break of exercise 11 Step 4 on EKS) | W4 Change; Spike 1; Risks | Run spike 1 on EKS, or state the ship order: run the spike first, then commit one of the two forms. |
| 4 | COLD-READ | W5 `README.md:173` prompt change, and Done-when zsh check | The change adds the zsh lines but doesn't say where they go. If they land in the same fenced block as the bash `export PS1` line, a zsh user who pastes the whole block gets a bash PS1 that is harmless but noisy. The Done-when check greps `^(setopt PROMPT_SUBST\|export PROMPT=)`, so the new lines must start at column 0 and sit in a separate block from the bash line. | neither: the placement is cosmetic and the check pins the shape | README:173 | Name the placement, for example "a separate fenced block labelled zsh". |
| 5 | GAP | W2 exercise 09 Step 4 and `taints-tolerations.yaml` | The manifest header comment (`taints-tolerations.yaml:1-8`) and any other reader of the file now need the `sed` instruction, because a plain `kubectl apply` of the file leaves `tolerating-pod` Pending. The Change list doesn't mention updating the header comment. Only the README is said to pipe through `sed`. | neither: Risks documents it, and nothing else applies this file | `git grep taints-tolerations` finds only README:113 | Add one line to the manifest header saying to apply it through `sed`. |
| 6 | COLD-READ | W1 exercise 12 Step 4 and Done when | The new opening `kubectl apply -f ../03-deployments/...` assumes Step 4 is run from `exercises/12-troubleshooting` and that exercise 03's Deployment is `web-app` with `app=web-app`. Those do hold (`clusterip-service.yaml:11-12`). The spec says to "add the matching deletes to Step 8" without giving them. The README's Step 8 already has `kubectl delete -f manifests/` and ignore-not-found lines, so the reader has to work out the exact form. | neither: the intent is clear and the fix is small | 12 README:238-244 | Give the two delete lines. |
| 7 | ASSUMPTION | Background, `set image` item (`README.md:187,196`) | The offline claim that `unable to find container named "web"` appears, and that `nginx=` works, is tagged an assumption and rests on an unrecorded local run. The W1 Done-when offline check would settle only the `nginx=` side. The check also writes to `/tmp/web.yaml` and relies on `kubectl create deployment --dry-run=client` naming the container after the image. That naming rule is standard kubectl behaviour but is not cited. | neither: the Done-when check confirms it | W1 Done when, "Offline" | Run the offline check. |
| 8 | ASSUMPTION | W2 and Background, exercise 10 Step 5 slot count | "About 11 system Pods" and "about 3 slots" are assumptions. The Done-when check `grep -c 'Too many pods'` prints 0 only if the count is right, and it is only run on EKS. The quota arithmetic holds: limits.memory 4Gi ÷ 256Mi gives 16, while requests.memory 2Gi ÷ 64Mi gives 32 and limits.cpu 4 ÷ 200m gives 20. | neither: W2 deletes the quota Pods, so the claim is moot once it lands | `resource-quota.yaml:22-26,45-47` | Run the EKS pass. |
| 9 | ASSUMPTION | W2 Done when, exercise 10 `wc -l` | `wc -l` prints 17 only because `default-limits-pod` (1) + `pod-1`…`pod-15` (15) + the header line (1) = 17. This holds if Step 3's Pod is still present. The Done-when's other check (prints `0` after `delete pods --all`) is also `wc -l`, and `--no-headers` there gives 0. The two checks count differently, which the spec doesn't flag. | neither: the arithmetic is correct | 10 README:133-170 | Run on kind. |
| 10 | STALE | W5 exercise 12 Step 6 and the Done-when `grep -c 'kubectl events' ... at least 3` | Exercise 12's objectives line 8 already says `kubectl events` and Step 6 uses `get events`. The "at least 3" count depends on how many mentions the objective already contributes. Reading the file doesn't settle this. | neither | 12 README:8,183,189 | Count the matches after the edit. |

Counts: 10 findings - 1 correctness, 1 requirement, 8 neither
Neither: 4, 5, 6, 7, 8, 9, 10
Cold read: no - the first place I had to stop was the Design section's "kind v0.33.0, the version commit `d27b56c` used", with no cluster config given for the "On kind" checks.
Needs a run: 3, 7, 8, 9, 10

The first finding in the table is graded correctness and the second requirement, but I could only put one correctness row and one requirement row in a table that is meant to list correctness rows first. Row 3 is the correctness row. Rows 1 and 2 are the requirement rows, so the counts above should read 1 correctness, 2 requirement, 7 neither. I also did not check W1's exercise 05 `wget` test or the `--overrides` quoting in W2 beyond reading them.

## Changes since the review

- Not reviewed: W4 rewrites exercise 11's README line 28, and its grep adds `does \*\*not\*\* enforce`, from cold review row 1, on 2026-10-09.
- Not reviewed: the Design names the kind test bed (default one-node config, S1 assumption, a `BLOCKED` probe before exercise 11's checks), from cold review row 2, on 2026-10-09.
- Not reviewed: W4 states the ship order for the DNS rule (spike 1 first, then one of the two forms), from cold review row 3, on 2026-10-09.
- Not reviewed: W5 places the zsh prompt in its own fenced block, from cold review row 4, on 2026-10-09.
- Not reviewed: W2 updates `taints-tolerations.yaml`'s header to say to apply it through `sed`, from cold review row 5, on 2026-10-09.
- Not reviewed: W1 gives exercise 12 Step 8's two delete lines, from cold review row 6, on 2026-10-09.
- Not reviewed: Background cites kubectl's container-naming code for the `set image` claim, from cold review row 7, on 2026-10-09.
- Not reviewed: Background says W2's EKS check settles the Pod-slot count, from cold review row 8, on 2026-10-09.
- Not reviewed: W2 explains what the `wc -l` of 17 counts, from cold review row 9, on 2026-10-09.
- Not reviewed: W5's `kubectl events` count names its three sources, from cold review row 10, on 2026-10-09.
- Not reviewed: the Design cites commit `d27b56c`'s message for kind v0.33.0, and W2 says the manifest header is updated, not already worded so, from verifier round 2, on 2026-10-09.
- Not reviewed: W4's `8.8.8.8` check is marked as an assumption for spike 1, from verifier round 2, on 2026-10-09.
- Not reviewed: W5's zsh check uses two exact greps, and W1's offline check says neither command needs a cluster, from verifier round 2, on 2026-10-09.
