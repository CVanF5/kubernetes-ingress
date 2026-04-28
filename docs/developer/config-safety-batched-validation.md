# Config Safety Batched Validation Design

## Problem

When `enable-config-safety` is enabled, the controller currently validates generated NGINX configuration by running `nginx -t -q` from `ConfigRollbackManager.CreateMainConfig`, `CreateConfig`, and `CreateStreamConfig`.

That is safe, but it scales poorly:

- each generated resource file can trigger a full-tree `nginx -t`;
- unchanged files can still trigger `nginx -t` before being reported as already applied;
- startup and informer sync paths can reconcile the same resources multiple times;
- an invalid Kubernetes resource remains in the cluster and can be retried by later sync paths.

The result is repeated full parsing of the complete NGINX config tree. In large clusters this can turn startup from seconds into minutes.

## Goals

- Preserve the safety property: never reload an invalid NGINX configuration.
- Reduce duplicate full-tree `nginx -t` runs during startup and batch/ConfigMap updates.
- Allow any number of bad resources to be individually excluded while valid resources are promoted in the same batch.
- Report validation failures against the most useful Kubernetes object.
- Keep validation as a full-tree `nginx -t` against the actual live config tree.
- Bound the impact of cluster size on availability:
  - **Existing-service availability is independent of ingress object count.** A bad new or updated configuration must never reduce availability of resources already serving traffic, at any cluster size. The prior-good snapshot makes this a constant-time invariant: failing candidates are reverted before NGINX reloads, so workers never observe the bad config.
  - **Time-to-apply for valid changes scales at most linearly with the size of the rendered config tree.** Batching collapses `N × O(N)` per-file validation into `1 × O(N)` batched validation, removing the super-linear blow-up on startup and mass-update paths. The linear floor is a property of `nginx -t` itself (full-tree parse cost) and is preserved by design — full-tree validation remains the authority. Phase 1 holds this bound on the success path and on attributable failures (selective revert: `(B+1) × O(N)` for `B` bad resources); ambiguous failures fall back to today's per-file replay, which later phases progressively eliminate.
- **Bound memory overhead during validation.** Snapshot storage must not roughly double the controller's resident memory. Large generated configs (tens or hundreds of MB) are common in big clusters; holding both the prior content and the new content in process memory simultaneously would balloon the controller exactly when `nginx -t` is also loading the new content into its own address space. Snapshots are kept on disk via rename-based shadow files; process memory holds only metadata (paths, owners, "had prior version" flags).

## Non-Goals

- Do not replace full-tree validation with isolated per-Ingress validation.
- Do not assume that NGINX config validity is compositional.
- Do not silently drop user configuration without reporting an event/status.
- Do not introduce a parallel staging filesystem, symlink swap, or path-rewriting promotion mechanism.

## Current Behavior

The current `ConfigRollbackManager` writes one file at a time into the live `/etc/nginx` tree, runs `nginx -t -q`, and rolls back that file to its prior content on failure.

The shape is correct — validate against the real tree, with file-level rollback — but it is invoked per generated resource. For a batch of `N` resources, that produces at least `N` full-tree `nginx -t` runs during initial generation, plus additional runs from service, endpoint, secret, and ConfigMap resyncs that re-render the same resources. In a measured 8-Ingress + 1-invalid scenario at startup, the controller ran `nginx -t` ~35 times — roughly 4× the resource count — because the same Ingresses were reconciled multiple times through different event sources, and unchanged content still triggered validation.

If validation fails:

- the candidate file is rolled back to the previous content if a backup exists;
- otherwise, non-main config files are deleted;
- an error is returned to the controller;
- the affected resource receives an event such as `AddedOrUpdatedWithError`.

This gives good safety and reasonable resource attribution, but repeats expensive validation work. The proposed design extends it from per-file to per-batch.

## Proposed Approach

In-place batched validation:

1. Filter the batch: drop any candidate whose rendered content is byte-identical to what is already on disk. That content has already been validated and is loaded by the running NGINX — there is nothing to test, write, or reload for those files. If every candidate is a no-op, the batch returns immediately with no `nginx -t` and no reload.
2. For every remaining file, rename the existing file to `path.prev` — an on-disk shadow. No file content is held in process memory.
3. Write all candidates into `/etc/nginx`.
4. Run one full `nginx -t -q`.
5. On success: `nginx -s reload`. Discard shadow files. Report.
6. On failure: identify the owning resource, restore its file from `path.prev` (for updates) or delete the candidate (for first-time creates), then retest.
7. If the loop cannot converge: restore every file in the batch from its shadow, do not reload, and emit a batch-level error event.

`nginx -t` is a read-only syntax check; the running master and workers continue serving their loaded config until `nginx -s reload` is issued. Validation reads the same files a subsequent reload will load.

## Multi-Replica Behavior

NIC typically runs with two or more controller replicas behind a Service or LoadBalancer. Each replica observes the same cluster state but maintains its own independent NGINX process and its own local `/etc/nginx`. The implications for batched validation:

- **Shadows are pod-local.** The on-disk `.prev` files live in each pod's `/etc/nginx`. Replicas do not share validation state or prior-good snapshots.
- **Each replica reaches its own verdict.** A bad ConfigMap or resource is observed by every replica and validated independently. Validation is deterministic given equal binary versions and equal cluster state, so replicas converge on the same outcome in steady state. They can diverge transiently during a rolling upgrade where the binary version differs across replicas.
- **A fresh pod has no prior-good.** When a replica starts (cold start, node failure, rolling restart), its `/etc/nginx` is empty. The controller renders desired state from cluster, and the cold-start path applies — there is no shadow to revert to. The cold-start policy (see Global Failure Policy) governs what happens if cluster state contains a bad required global input at this moment.
- **Rolling restart during a bad-input window.** Existing replicas continue serving previous-good config from their pod-local snapshots. New replicas that come up during the window apply the cold-start policy. The cluster transitions through a mixed state until either the bad input is corrected or the rollout completes. The recommended cold-start policy (fail readiness, do not take Service traffic) preserves availability through this transition.

Snapshots, shadow files, and validation outcomes are pod-local.

## Skip on Unchanged Content

Today's `ConfigRollbackManager` runs a full `nginx -t` even when the candidate content is byte-identical to what is already on disk (`internal/nginx/rollback_manager.go:49`). For a single resource that has not changed, that is one full-tree validation per reconciliation — and reconciliation runs frequently, triggered by service, endpoint, and secret events that often regenerate output identical to what is already loaded.

The new path filters these out before any work happens:

```go
if bytes.Equal(existingContent, content) {
    return false, nil    // already applied and live; nothing to validate
}
```

The safety argument is straightforward: the content on disk has already been validated by an earlier reconciliation and is live in the running NGINX. Re-validating it cannot reveal new information, because nothing has changed — neither the input nor the binary. Skipping the test is correct, not a shortcut.

This optimisation is independent of batching but compounds with it: a batch of mostly-unchanged candidates filters down to a small set of actually-changed files, and only those go through the validate/reload loop. The relative contribution of skip-on-unchanged versus batching depends on the event mix in a given workload — the Phase 1 instrumentation prerequisite (see Phased Implementation) measures this directly so the projection can be confirmed before the new path becomes default.

## Ownership Index

The configurator should maintain, for each batch, an in-memory map from file path to owning Kubernetes resource or controller-level source:

```go
type ResourceRef struct {
    Kind      string
    Namespace string
    Name      string
}

type CandidateOwner struct {
    Resource *ResourceRef
    Source   CandidateSource
}

type CandidateSource string

const (
    SourceIngress          CandidateSource = "Ingress"
    SourceVirtualServer    CandidateSource = "VirtualServer"
    SourceTransportServer  CandidateSource = "TransportServer"
    SourceConfigMap        CandidateSource = "ConfigMap"
    SourceMGMTConfigMap    CandidateSource = "MGMTConfigMap"
    SourceSecret           CandidateSource = "Secret"
    SourceGlobalConfig     CandidateSource = "GlobalConfiguration"
    SourceControllerConfig CandidateSource = "ControllerConfig"
)
```

For each batch the configurator builds two maps:

```go
ownerIndex map[string]CandidateOwner    // path -> owning resource/source
shadows    map[string]ShadowMetadata    // path -> { hadPriorVersion bool, owner, ... }
                                         // Prior content lives on disk at path+".prev",
                                         // not in process memory.
```

Example ownership entries:

```text
/etc/nginx/conf.d/default-cafe.conf
  -> Ingress default/cafe

/etc/nginx/stream-conf.d/default-dns.conf
  -> TransportServer default/dns

/etc/nginx/nginx.conf
  -> ConfigMap nginx-ingress/nginx-ingress or controller defaults

/etc/nginx/secrets/default-cafe-tls
  -> Secret default/cafe-tls
```

Use the explicit path-to-owner map rather than deriving ownership from filenames. Filenames carry namespace/name information today, but a map avoids ambiguity and handles resource types with different filename schemes.

## Validation Loop

The loop below is the end-state. Phase 1 ships a much smaller subset — see Phased Implementation.

```go
candidates = filterUnchanged(candidates)     // drop byte-identical no-ops
if len(candidates) == 0 {
    return nil                                // nothing to test, write, or reload
}
shadows := shadowExisting(targetPaths)     // rename existing -> path.prev (on-disk, no content in memory)
defer finalizeShadows(shadows)              // discard on success, restore on revert
ownerIndex := buildOwnerIndex(candidates)
writeAll(candidates)                          // atomic per-file

excluded := map[ResourceRef]error{}
for {
    err := nginxTest()                        // nginx -t -q on the live tree
    if err == nil {
        nginxReload()
        reportExcluded(excluded)
        return nil
    }

    failure := classifyNginxTestFailure(err, ownerIndex)

    switch failure.Kind {
    case PerResourceFailure:
        revertResource(failure.Resource, shadows)
        excluded[failure.Resource] = err
        continue

    case GlobalInputFailure:
        revertGlobalInput(failure.Source, shadows)
        rejectGlobalInput(failure.Source, err)
        continue

    case UnknownFailure:
        found := isolateBySearch(candidates, shadows, ownerIndex)
        if found == nil {
            revertAll(shadows)              // batch fails closed
            return err
        }
        revertResource(*found, shadows)
        excluded[*found] = err
        continue
    }
}
```

This loop runs multiple `nginx -t` commands only when there are failures. The success path is one full-tree validation per batch.

`revertResource` renames the `.prev` shadow back over the candidate path for updates, or removes the candidate file for first-time creates — both are O(1) operations with no content I/O. `revertAll` is the batch-level abort: every file the batch touched is restored from its shadow, and no reload is issued, leaving the live tree exactly as it was before the batch began.

## Rollback Semantics

Reverting a candidate has three cases:

- **Update of an existing resource**: restore the file's prior content from its on-disk shadow. Today's per-file rollback already provides this property; the batched loop preserves it. The data plane retains the prior version of the resource as long as the controller has not yet reloaded.
- **First-time create**: delete the file. The resource was never serving traffic; exclusion is the correct outcome.
- **Delete of an existing resource**: deletes are file removals, not file writes. They cannot fail validation on their own. If a delete contributes to an interaction failure (another resource still references the removed file), the failure is handled as `UnknownFailure` via the isolation search.

### On-Disk Shadow Files

Snapshots are stored on disk, not in process memory. NGINX configs in large clusters can run to tens or hundreds of megabytes; holding a Go-side `map[string][]byte` of every candidate's prior content during a batch would roughly double the controller's resident memory at exactly the moment that `nginx -t` is also loading the same content into its own address space.

Instead, before writing each candidate the controller renames the existing file to a sibling shadow:

```go
// Before write:
os.Rename(path, path + ".prev")        // atomic, O(1), no content I/O
writeFile(path, candidate.content)

// To revert (update case):
os.Rename(path + ".prev", path)        // atomic restore

// To revert (first-time create):
os.Remove(path)                        // no shadow exists; just unlink

// To finalize on batch success:
os.Remove(path + ".prev")              // discard shadow
```

Properties:

- **Memory cost is O(paths) for metadata only** — paths, owners, and a boolean "had prior version" per file. File content never enters Go's heap.
- **Rename is atomic and O(1)** regardless of file size, so snapshot cost is negligible even for very large generated files.
- **The `.prev` extension does not match `*.conf` include globs**, so NGINX never picks up shadow files during validation or reload.
- **Shadows live on the same filesystem** as the original — no cross-volume copy concerns.
- **Cleanup is one `Remove` per shadow** at end of batch, or `Rename` back on revert.
- **A controller crash mid-batch leaves shadow files behind**, but `/etc/nginx` is ephemeral on pod restart in standard NIC deployments (writable container layer or `emptyDir` mount), so the next pod re-renders cleanly from cluster state.

### Cleanup Discipline

Every batch path must `defer` its shadow cleanup so successful, failed, and panicked batches all leave a clean tree. A leaked `.prev` file is not a correctness issue (NGINX ignores it via the include-glob extension) but is operationally noisy.

The candidate write itself should still use atomic rename-from-temp (`createFileAndWriteAtomically`) so the brief moment when the new candidate exists on disk is observable as fully written rather than partial. This is a Phase 4 hardening item — the current `os.Rename`-based shadow approach is already crash-tolerant given NIC's ephemeral `/etc/nginx`.

## Failure Attribution

### Attribution Mechanism (Phase 1)

`nginx -t -q` reports the offending file path in its error output. The existing `nginxTestError` helper (`internal/nginx/utils.go:42`) already cleans up the stderr — it strips the trailing `nginx: configuration file ... test failed` summary line and joins the remaining lines with `"; "`. The cleaned string is what attribution operates on.

Real errors include the path directly:

```text
nginx: [emerg] invalid value "invalid" in "sub_filter_once" directive in /etc/nginx/conf.d/default-cafe.conf:21
nginx: [emerg] unknown directive "foobar" in /etc/nginx/conf.d/default-cafe.conf:5
nginx: [emerg] cannot load certificate "/etc/nginx/secrets/default-cafe-tls": ...
nginx: [emerg] open() "/etc/nginx/conf.d/foo.conf" failed (2: No such file or directory)
```

The classifier extracts paths from the error string, then looks each up in the per-batch ownership index:

```go
// All NIC-generated files live under /etc/nginx/. Match path tokens
// terminated by whitespace, colon (line/column suffix), or quote.
var pathRe = regexp.MustCompile(`/etc/nginx/[^\s:"']+`)

func classifyNginxTestFailure(err error, owners map[string]CandidateOwner) Failure {
    for _, raw := range pathRe.FindAllString(err.Error(), -1) {
        path := strings.TrimRight(raw, ".,;)")          // trailing punctuation
        owner, ok := owners[path]
        if !ok {
            continue                                     // not a path we wrote this batch
        }
        switch owner.Source {
        case SourceIngress, SourceVirtualServer,
             SourceVirtualServerRoute, SourceTransportServer:
            return Failure{Kind: PerResourceFailure, Resource: *owner.Resource}

        // Phase 2: global/shared file ownership
        case SourceConfigMap, SourceMGMTConfigMap,
             SourceGlobalConfig, SourceSecret:
            return Failure{Kind: GlobalInputFailure, Source: owner.Source}
        }
    }
    return Failure{Kind: UnknownFailure}                 // no parseable path matched the index
}
```

Three cases the classifier cannot pin down — all fall through to the revert-all + per-file replay path in Phase 1:

- **Path is in the index but maps to a global/shared source** (`nginx.conf`, ConfigMap-derived files, Secret files). Returned as `GlobalInputFailure`; Phase 1 falls back. Phase 2 handles it natively.
- **Path is referenced in the error but not in the candidate set** (e.g., a previously-rendered shared file the candidate references). Returned as `UnknownFailure`.
- **Error has no parseable path.** Rare, since `nginx -t` almost always names the offending file, but possible for some early-init or non-config errors. `UnknownFailure`.

`nginx -t` reports the first error it encounters and stops, so each iteration of the validation loop pins down at most one bad resource. Total attribution cost is `(B + 1)` `nginx -t` runs for `B` bad resources — the bound named in Goals.

The output format is not formally specified by NGINX, but the `in <path>:<line>` and quoted-path patterns have been stable across versions for many years. If a future NGINX changes the format such that the regex finds nothing, attribution returns `UnknownFailure` and the per-file replay fallback takes over — no safety regression.

### Per-Resource Generated File (Phase 1)

When the classifier returns `PerResourceFailure`, the loop reverts that file from its `.prev` shadow (or removes it if first-time create) and retests. This is the dominant Phase 1 attribution path: NGINX names a `conf.d/*.conf` or `stream-conf.d/*.conf` file, the ownership index maps it to a single `Ingress` / `VirtualServer` / `VirtualServerRoute` / `TransportServer`, and selective revert isolates the bad resource without disturbing the rest of the batch.

Confidence: high.

### Shared or Global File (Phase 2)

If NGINX reports `nginx.conf`, TLS passthrough host config, a generated shared map, a secret file, or an App Protect file, the failure should not automatically be blamed on the resource that happened to be processed last.

Examples:

- `main-snippets`, `http-snippets`, and `stream-snippets` from the controller ConfigMap can break `nginx.conf`.
- `server-snippets` and `location-snippets` from the controller ConfigMap are global user inputs that may be rendered into many per-resource files.
- `main-template`, `ingress-template`, `virtualserver-template`, and `transportserver-template` from the controller ConfigMap can change generated output at runtime.
- TLS, JWK, htpasswd, CA, and management secrets are runtime Kubernetes objects that write shared files.
- GlobalConfiguration can affect listener/global routing configuration.

For global input changes, prefer rejecting the global input update and preserving the last known-good global inputs rather than excluding every resource that fails as a consequence.

Confidence: medium-high. Requires source tracking beyond path ownership.

### Global Failure Policy (Phase 2)

A bad global or shared input must not be handled the same way as a bad per-resource generated file.

If one Ingress candidate fails because its own generated config is invalid, exclude that resource and reload the rest. If a global input fails, the safer policy is to revert that global input and keep the previous known-good content rather than blocking or excluding every affected resource.

Recommended policy:

- Bad per-resource config: revert that file, report the resource, reload the rest.
- Bad optional global ConfigMap input: revert the global file, report the ConfigMap with `UpdatedWithError`, reload using previous-good or default global config.
- Bad required global/controller input: do not reload; the live tree retains previous-good config.
- Cold start with bad required global input: render a skeleton config that lets NGINX start, but fail the controller's readiness probe so the pod is not added to the Service backends. Existing replicas with previous-good config keep serving traffic; the failing pod surfaces the error via standard Kubernetes readiness signals where operators expect to find it. This is the recommended default — it preserves the K8s-native "rolling update with bad config does not take down the cluster" property and avoids the silent-degradation mode of serving an unrelated default config. Final policy is subject to product agreement; alternative options (CrashLoop on failure, serve minimal config without readiness gating) trade visibility against availability differently.

This distinction matters because global ConfigMap snippets and templates are runtime user inputs, not only install-time Helm or manifest settings. A bad `main-snippets`, `http-snippets`, `stream-snippets`, or custom template can break the complete generated tree. In that case the controller should report the global source as the failing input rather than marking every Ingress, VirtualServer, or TransportServer resource as invalid.

Existing traffic must be preserved whenever a previous-good snapshot exists. A failed global update must not make already-working Ingress resources unavailable. On cold start there is no previous-good content to preserve, so the fallback policy must decide whether to run with defaults/minimal config or fail visibly.

### Per-Resource File With Global Snippet Source (Phase 2)

This is the subtle case. A bad global `server-snippets` value can be rendered into every Ingress file. NGINX may report the first generated Ingress file, but the root cause is the ConfigMap.

The configurator should track whether a batch includes changed global inputs. If a per-resource file fails during a global-input update, the controller should first test whether the same resource succeeds with the previous-good global inputs (re-render with the prior values, write, retest). If it does, attribute the failure to the global input.

Possible source-tracking aids:

- wrap inserted ConfigMap snippets with generated comments identifying the source;
- record template section ownership while rendering;
- store the global-input generation used to render each candidate file;
- compare candidate output generated with previous and new global inputs.

Confidence: medium. This is feasible, but it is more complex than path-to-owner mapping.

### Unknown or Interaction Failure (Phase 3)

Some failures are caused by combinations:

- two resources collide only when both are present;
- a shared name is generated from multiple resources;
- a template bug produces invalid global structure;
- NGINX reports an error without a useful path.

Fallback to a bounded search algorithm (bisection or delta debugging) over the candidate set. Each search step is still a full-tree `nginx -t`, not isolated resource validation.

The search must be bounded: after a configurable iteration cap, abandon attribution, revert the entire batch via `shadows`, and emit a batch-level error. This prevents pathological batches from blocking promotion indefinitely.

Confidence: medium.

## Reporting

For excluded per-resource candidates (Phase 1):

- Ingress: emit `AddedOrUpdatedWithError` event.
- VirtualServer / VirtualServerRoute: emit event and set status to `Invalid`.
- TransportServer: emit event and set status to `Invalid`.

For rejected global inputs (Phase 2):

- ConfigMap: emit `UpdatedWithError`.
- MGMT ConfigMap: emit `UpdatedWithError`.
- GlobalConfiguration: emit and update existing status path.
- Secrets: emit on the controller Pod or owning object, matching current special-secret behavior.

For batch-level aborts (Phase 3, entire batch reverted from shadows):

- emit a batch-level event on the controller Pod listing every candidate that was in the batch;
- include the final `nginx -t` error.

The message should include:

- the `nginx -t` error;
- whether previous-good content was retained;
- whether the candidate resource was excluded from the reloaded config.

## Performance Expectations

Today (per-file rollback, including no-op writes):

```text
N resource writes * full nginx -t cost
```

No-op batch (all candidates byte-identical to disk):

```text
0 nginx -t runs + 0 reload
```

Batched success path with `C` actually-changed candidates:

```text
1 full nginx -t + 1 reload (if C > 0)
```

Failure path with `B` directly-attributable bad resources:

```text
(B + 1) full nginx -t runs + 1 reload (if any candidates remain)
```

Batch-abort path (search exhausted or all changed candidates bad):

```text
bounded number of nginx -t runs + 0 reload + revert-all from shadows
```

The savings come from two effects: collapsing genuine multi-resource changes into one validation, and skipping validation entirely for reconciliations that regenerate identical content. In the observed 8-Ingress + 1-invalid scenario today produces ~35 `nginx -t` runs at startup; with both effects in place we expect a single-digit count, with the exact split between the two effects dependent on the event mix. The Phase 1 instrumentation prerequisite confirms this directly before the new path becomes default.

## Phased Implementation

The full design (ownership index, per-resource attribution, global input attribution, bisection) is the end state. To keep changes review-sized, ship in phases. Each phase is independently shippable behind the experimental flag.

### Phase 1: Batched Validation with Per-Resource Attribution and Selective Revert

The minimum reviewable change. Adds a batched code path that runs one `nginx -t` per batch in the success case, parses `nginx -t` output to attribute failures to the owning resource, and selectively reverts failing candidates while promoting the rest. Falls back to today's per-file behavior only when attribution is ambiguous.

**Prerequisite — measurement.** Before flipping the new flag in any environment, instrument the existing per-file rollback path to count how many calls hit the byte-identical "already applied" branch (`internal/nginx/rollback_manager.go:48`). This baseline measurement confirms how much of the projected savings comes from skip-on-unchanged versus batching, and identifies workloads where the projection does not hold. The instrumentation is a small, low-risk change that can land in its own PR and stay enabled regardless of the new flag.

```go
candidates = filterUnchanged(candidates)     // drop byte-identical no-ops
if len(candidates) == 0 {
    return nil                                // nothing to test, write, or reload
}
shadows := shadowExisting(targetPaths)       // rename existing -> path.prev (on-disk)
defer finalizeShadows(shadows)                // discard on success, restore on revert
ownerIndex := buildOwnerIndex(candidates)
writeAll(candidates)                          // reuse existing write helpers

excluded := map[ResourceRef]error{}
for {
    err := nginxTest()
    if err == nil {
        nginxReload()
        reportExcluded(excluded)
        return nil
    }

    failure := classifyNginxTestFailure(err, ownerIndex)
    if failure.Kind == PerResourceFailure {
        revertResource(failure.Resource, shadows)
        excluded[failure.Resource] = err
        continue
    }

    // Ambiguous: shared/global file, no parseable path, or unattributed.
    // Global-input attribution and bisection are deferred to later phases.
    revertAll(shadows)
    return fallbackToPerFileValidation(candidates)
}
```

In scope:

- skip `nginx -t` and reload entirely when candidate content is byte-identical to what is on disk;
- batched writes with a single `nginx -t` on the success path;
- on-disk shadow snapshots via rename-to-`.prev` (no file content kept in process memory);
- path-to-owner ownership index;
- per-resource attribution by parsing `nginx -t` output for a generated file path;
- selective revert and retest loop for attributable failures;
- revert-and-replay fallback to the existing per-file path when attribution is ambiguous;
- per-resource events on excluded candidates, matching today's `AddedOrUpdatedWithError` shape;
- new flag `enable-batched-config-safety`, off by default. **Flag precedence:** the new flag has effect only when `enable-config-safety` is also on (it is a strict refinement of config safety, not a replacement). When both are on, the batched path is used for all reconciliations and the old per-file path is reachable only as the ambiguous-failure fallback. When `enable-config-safety` is off, the new flag has no effect.

Out of scope (deferred to later phases):

- global vs per-resource failure distinction (the `GlobalInputFailure` arm);
- prior-global-input re-render attribution check;
- bounded bisection for unattributed failures;
- adoption of `createFileAndWriteAtomically` in batch writes;
- new event types beyond per-resource exclusion and the per-file path's existing events.

Costs:

- no-op batch (all candidates byte-identical to disk): 0 `nginx -t` + 0 reload;
- success with changes: 1 `nginx -t` + 1 reload;
- attributable failure with `B` bad resources: `(B + 1)` `nginx -t` runs + 1 reload (if any candidates remain);
- ambiguous failure: 1 batched `nginx -t` + revert-all + the existing per-file path (today's behavior).

### Phase 2: Global Input Attribution

Add source tracking for ConfigMap snippets, templates, and shared secrets. Adds the `GlobalInputFailure` arm and the prior-global-input re-render attribution check described in "Per-Resource File With Global Snippet Source."

### Phase 3: Bounded Bisection

Add the `UnknownFailure` arm: bisection over the candidate set with a configurable iteration cap. On exhaustion, revert all and emit a batch-level event listing every candidate.

### Phase 4: Operational Hardening

- adopt `createFileAndWriteAtomically` consistently across batch writes;
- add metrics (count, duration, outcome labels) and event coverage;
- once stable, remove the experimental flag and replace per-file validation in batch paths.
