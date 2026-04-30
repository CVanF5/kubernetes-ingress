# Hostless Ingress Aggregation Design

## Problem

The Kubernetes Ingress spec permits rules with no `host` field, with the semantic that the rule applies to all inbound HTTP traffic regardless of the request's Host header. NGIC has rejected such rules since 2017 (issue #209), citing NGINX's hard limit of one `default_server` per `address:port`.

The constraint is real (`ngx_http.c:1305-1318`: writing `default_server` on two `listen` directives for the same `address:port` is `EMERG` at config-load time), but it bounds the **rendered NGINX config**, not the **set of Ingress resources**. The community ingress-nginx controller demonstrates that N hostless Ingresses across N namespaces can be supported by emitting a single `server { listen 80 default_server; server_name _; ... }` block and merging paths from all hostless Ingresses into it. The constraint is satisfied because there is still only one `default_server` block; it just happens to contain locations sourced from many Ingress objects.

PR #9614 establishes the foundation: a feature flag, the synthetic file slot at `00-default-server.conf`, an `IsDefaultServer` flag on the per-Ingress server template, validation hooks, and a single-Ingress claim model. That work is the right starting point. It proves the file-slot mechanism, the template surgery, and the validation contract.

This design **builds on** that foundation by generalising the single-claim model into an aggregation model: instead of one Ingress owning the empty-host slot, all hostless Ingresses contribute paths to a single shared `default_server` block. Path-level arbitration replaces Ingress-level arbitration, matching the multi-tenant catch-all pattern users have asked for since 2017 and the behaviour the community ingress-nginx controller already provides. NGINX's physical constraint is preserved: there is still exactly one `default_server` block per `address:port`; it simply contains locations sourced from many Ingress objects.

## Goals

- Support an arbitrary number of hostless Ingresses across an arbitrary number of namespaces, contributing paths to a single shared catch-all server.
- Resolve path conflicts deterministically using NGIC's existing `chooseObjectMetaWinner` (creation timestamp, UID tiebreak). Behavior matches ingress-nginx.
- Preserve NGINX's "one `default_server` per `address:port`" constraint by emitting exactly one synthetic server block.
- Per-Ingress server-level configuration cannot affect other Ingresses' traffic. The catch-all server's listen ports, TLS, server tokens, and server-level annotations are controller-owned.
- Opt-in via `--allow-empty-ingress-host`. Default off. Behavior with the flag off is byte-identical to today.
- Cross-namespace merge is supported by default. No `Wins()` arbitration uses namespace.
- Reuse existing NGIC machinery: `Configuration.buildHostsAndResources` host arbitration, `chooseObjectMetaWinner` tiebreak, `MergeableIngresses`-style location aggregation, `IngressEx.ValidHosts` per-host gating.

## Non-Goals

- Not extending hostless support to VirtualServer/VirtualServerRoute. Scope is `networking.k8s.io/v1` Ingress only.
- Not supporting `spec.defaultBackend` semantics. The catch-all fallback (return code, health endpoint) is controller-owned via existing ConfigMap keys.
- Not introducing per-Ingress TLS for the catch-all server. The catch-all uses the controller's default secret (`/etc/nginx/secrets/default`) or `ssl_reject_handshake`, as today's static block does.
- Not changing path-conflict semantics for hosted Ingresses. The aggregate's path arbitration applies only to its own members.
- Not auto-promoting hostless Ingresses to mergeable-ingress masters. The mergeable-ingress mechanism (`nginx.org/mergeable-ingress-type`) is forbidden on hostless Ingresses.
- Not shipping as a separate parallel implementation. This design generalises PR #9614's single-claim sync into a multi-member aggregator; the file slot, feature flag, validation hooks, and template flags carry over directly.

## Current Behavior

`internal/k8s/validation.go:validateIngressSpec` rejects any rule with `host == ""` as `field.Required`.

`internal/configs/version1/nginx.tmpl` and `nginx-plus.tmpl` embed a static default-server block:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    server_name _;
    location / { return {{.DefaultServerReturn}}; }
    # optional health endpoint
}
```

This block is the only catch-all today. It cannot be customized per Ingress; it returns `DefaultServerReturn` (configurable via ConfigMap, default 404) for any unmatched request.

`Configurator.addOrUpdateIngress` writes one config file per Ingress (`<ns>-<name>.conf`). There is no aggregator that combines multiple Ingresses into one rendered file outside the mergeable-ingress (`master`/`minion`) mechanism.

`Configuration.buildHostsAndResources` (`internal/k8s/configuration.go:1502`) maintains `c.hosts map[string]Resource` with one resource per host string. Conflicting claims to the same host trigger `Resource.Wins()` arbitration; the loser is warned and its rule is suppressed via `IngressEx.ValidHosts[host] = false`.

## Proposed Approach

1. Reuse the PoC's `--allow-empty-ingress-host` feature flag (default false). All other changes are gated on the flag.
2. Introduce a new resource type `HostlessAggregateConfiguration`, keyed by the empty string in `Configuration.hosts`. The aggregate represents the set of all hostless Ingresses contributing to the cluster's catch-all server.
3. Extend `Configuration.buildHostsAndResources` to detect hostless rules across all Ingresses, arbitrate path conflicts using `chooseObjectMetaWinner`, and emit one aggregate resource per reconcile cycle.
4. Add `generateNginxCfgForHostlessIngresses` in `internal/configs/ingress.go`, modeled on the existing `generateNginxCfgForMergeableIngresses` (line 1103). It produces one `IngressNginxConfig` with a synthetic `Server` whose `Locations` are sourced from the aggregate's members.
5. Replace the PoC's `syncSyntheticDefaultServerConfig` with `syncHostlessAggregateConfig` in `Configurator`. After every Ingress add/update/delete, rewrite the single shared file `00-default-server` with either the aggregate's rendered content or a controller-emitted fallback if no hostless Ingresses exist.
6. Remove the static default-server block from `nginx.tmpl` and `nginx-plus.tmpl` only when the flag is on. With the flag off, the static block remains and behavior is unchanged.

## Resource Model

There are two viable shapes for representing the aggregate inside the Configuration layer. The PoC validates the second; the first remains the cleaner long-term option.

### Option 1: Aggregate as a Resource type (cleaner, more surgery)

A new type representing the cluster-wide aggregate:

```go
// HostlessAggregateConfiguration represents the union of all Ingress rules
// with no host, rendered as NGINX's single default_server block.
type HostlessAggregateConfiguration struct {
    Members    []*networking.Ingress
    PathOwners map[string]*networking.Ingress
    Warnings   []string
}
```

Implements `Resource`, registered at `c.hosts[""]`, fires `AddOrUpdate` change events when its identity changes via the existing `IsEqual`-driven detection. Downside: `processChanges` in `controller.go` dispatches by resource type (Ingress / VirtualServer / TransportServer); adding a fourth type means controller surgery and a new branch through `Configurator`.

### Option 2: Synthetic AddOrUpdate events for member Ingresses (PoC choice)

`rebuildHosts` emits a synthetic `AddOrUpdate` change for every Ingress with at least one empty-host rule. Each member flows through the existing per-Ingress pipeline (`createIngressEx` → `Configurator.AddOrUpdateIngress`); the aggregator hook in `addOrUpdateIngress` rerenders `00-default-server.conf` from cumulative state. No new resource type, no controller dispatcher changes.

Trade-offs:

- **Pro**: minimal pipeline surgery; existing event/status/warning machinery applies to each member for free.
- **Pro**: existing endpoint, secret, and policy resolution on the IngressEx all run unchanged.
- **Con**: aggregator runs N times per batch when N hostless Ingresses change together (idempotent but wasteful; debouncing is a follow-up).
- **Con**: changes are emitted unconditionally on every reconcile rather than gated by "did the aggregate actually change", causing extra reload work in pathological cases.

The PoC ships Option 2. A production implementation may upgrade to Option 1 for tighter change detection, or keep Option 2 with debouncing.

### IngressEx.ValidHosts under either option

`ValidHosts[""]` is `false` for hostless Ingresses regardless of which option is used. The aggregator walks `cnf.ingresses` directly and ignores `ValidHosts[""]`. The per-Ingress renderer (`generateNginxCfg`) explicitly skips empty-host rules under the flag so per-Ingress files don't emit invalid `server_name ""` blocks. Per-Ingress files for purely-hostless Ingresses end up containing only the comment header. Cosmetic wart, harmless.

### Cross-cutting use of ValidHosts in the controller

`createIngressEx` (`internal/k8s/controller.go`) iterates `ing.Spec.Rules` and skips rules where `!validHosts[rule.Host]` for the purpose of endpoint resolution. With `ValidHosts[""] = false`, that path skips endpoint resolution for hostless rules, leaving `IngressEx.Endpoints[svcKey]` empty and the aggregator rendering placeholder upstream addresses (`127.0.0.1:8181`). The carve-out: empty-host rules under the flag bypass the `validHosts` gate in `createIngressEx`. This is a real instance of `ValidHosts` carrying a second contract beyond rendering, worth documenting and respecting in any future refactor.

### Rejection-path carve-out

`Configuration.addProblemsForResourcesWithoutActiveHost` flags any Ingress whose every host slot lost arbitration as `Rejected: All hosts are taken by other resources`. With `ValidHosts[""] = false` for hostless Ingresses, this check incorrectly rejects them. The carve-out: when the flag is on and the Ingress has only empty-host rules, skip the rejection.

## Aggregation Semantics

**Per-path arbitration.** When two hostless Ingresses both define the same path, `chooseObjectMetaWinner(meta1, meta2)` (`internal/k8s/configuration.go:52`) selects the older. The losing Ingress receives a warning naming the winning Ingress; the losing path is omitted from the rendered aggregate. This matches `Wins()` semantics for hosted resources but applies at path granularity rather than resource granularity.

**Path equality is exact.** Two paths are considered conflicting when their `Path` strings and `PathType` values are equal. Different `PathType` values on the same `Path` string (e.g., `Exact /api` and `Prefix /api`) are not conflicts; both render. NGINX's longest-match rules then arbitrate at request time.

**Cross-namespace is invisible to arbitration.** `chooseObjectMetaWinner` compares creation timestamps and UIDs, neither of which is namespace-scoped. Two Ingresses in different namespaces with the same path are arbitrated identically to two in the same namespace.

**Member ordering is stable.** `Members` is sorted by `chooseObjectMetaWinner` order so the rendered file is deterministic given the same cluster state. This matters for reload skipping in `ConfigRollbackManager`: byte-identical output across reconciliations skips `nginx -t` and `nginx -s reload`.

**Path conflicts surface as warnings, not validation errors.** Two hostless Ingresses are valid in isolation; the conflict is a dynamic property of the cluster. A path conflict produces a `kubectl events`-visible warning on the losing Ingress, not a rejection. The losing Ingress remains in `Configuration.ingresses` and continues to contribute any non-conflicting paths it has.

**Annotation source per location.** Each rendered location carries the location-level annotations of its source Ingress (path rewrites, location snippets, location-level rate limits, location-level auth_request, proxy headers, etc.). The synthetic server block has no per-Ingress annotations.

## Worked Example

Two hostless Ingresses in different namespaces:

```yaml
# team-a/api-ingress (created at 2026-04-29T10:00:00Z)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  namespace: team-a
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 8080
      - path: /healthz
        pathType: Exact
        backend:
          service:
            name: api-svc
            port:
              number: 8080
---
# team-b/web-ingress (created at 2026-04-29T10:05:00Z)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: team-b
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /web
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
      - path: /static
        pathType: Prefix
        backend:
          service:
            name: static-svc
            port:
              number: 80
```

Neither has a `host` field. Both are picked up because `--allow-empty-ingress-host=true`. All four paths are unique across the two Ingresses, so arbitration is trivial: both Ingresses contribute all their paths.

`Configuration.buildHostsAndResources` registers a single `HostlessAggregateConfiguration` at `c.hosts[""]` with two members. `Configurator.syncHostlessAggregateConfig` calls `generateNginxCfgForHostlessIngresses` and writes:

`/etc/nginx/conf.d/00-default-server.conf`:

```nginx
upstream team-a-api-ingress-_-api-svc-8080 {
    zone team-a-api-ingress-_-api-svc-8080 256k;
    random two least_conn;
    server 10.244.1.5:8080 max_fails=1 fail_timeout=10s;
    server 10.244.1.6:8080 max_fails=1 fail_timeout=10s;
}

upstream team-b-web-ingress-_-web-svc-80 {
    zone team-b-web-ingress-_-web-svc-80 256k;
    random two least_conn;
    server 10.244.2.4:80 max_fails=1 fail_timeout=10s;
}

upstream team-b-web-ingress-_-static-svc-80 {
    zone team-b-web-ingress-_-static-svc-80 256k;
    random two least_conn;
    server 10.244.2.5:80 max_fails=1 fail_timeout=10s;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;
    status_zone _;

    ssl_certificate /etc/nginx/secrets/default;
    ssl_certificate_key /etc/nginx/secrets/default;

    # contributed by team-a/api-ingress
    location /api {
        set $service              "api-svc";
        set $resource_type        "ingress";
        set $resource_name        "api-ingress";
        set $resource_namespace   "team-a";

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://team-a-api-ingress-_-api-svc-8080;
    }

    location = /healthz {
        set $service              "api-svc";
        set $resource_type        "ingress";
        set $resource_name        "api-ingress";
        set $resource_namespace   "team-a";

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_pass http://team-a-api-ingress-_-api-svc-8080;
    }

    # contributed by team-b/web-ingress
    location /web {
        set $service              "web-svc";
        set $resource_type        "ingress";
        set $resource_name        "web-ingress";
        set $resource_namespace   "team-b";

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_pass http://team-b-web-ingress-_-web-svc-80;
    }

    location /static {
        set $service              "static-svc";
        set $resource_type        "ingress";
        set $resource_name        "web-ingress";
        set $resource_namespace   "team-b";

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_pass http://team-b-web-ingress-_-static-svc-80;
    }

    # synthesised fallback (emitted only when no member contributes a "/" path)
    location / {
        return 404;
    }
}
```

Things to notice:

1. **One `server` block, one `default_server` per listen socket.** NGINX's `address:port` constraint is satisfied. The aggregation is purely at the location/upstream level.
2. **`server_name _;`** matches anything. Combined with `default_server` on the listen socket, catches requests with no Host header, raw-IP requests, and SNI mismatches.
3. **Upstream names are namespace-prefixed** following the existing `<namespace>-<ingressName>-<host>-<service>-<port>` convention. The empty host is normalised to `_` (per the PoC's `emptyHostToken`). Cross-namespace upstreams coexist without name collision.
4. **`set $resource_*` is emitted per-location, not per-server.** The synthetic server has no owning Ingress, so server-level attribution would be wrong. Per-location attribution preserves Prometheus `serverZoneLabels` and access-log resource tracking by routing each request to the labels of its source Ingress.
5. **No server-level annotations.** `server_tokens`, `server_snippets`, `ssl_redirect`, `hsts`, App Protect bindings, JWT/basic-auth realms are all absent. They are forbidden on hostless Ingresses by the annotation contract; if either of these Ingresses had set one, validation would have rejected it before it reached the aggregate.
6. **The fallback `location /` is synthesized.** Neither member Ingress claims `/`, so the controller emits `return 404;` (the configured `DefaultServerReturn`). If `team-a/api-ingress` had defined a `/` path, that would have rendered instead and the synthesized fallback would have been suppressed (PoC's existing `HasRootLocation` flag).

### Path Conflict Variant

Suppose `team-b/web-ingress` is amended to also serve `/api`:

```yaml
# added to team-b/web-ingress
- path: /api
  pathType: Prefix
  backend:
    service:
      name: web-svc
      port:
        number: 80
```

`Configuration.buildHostsAndResources` now sees two claimants for `/api`:

| Path | Claimants | Winner |
| --- | --- | --- |
| `/api` | `team-a/api-ingress` (10:00:00Z), `team-b/web-ingress` (10:05:00Z) | `team-a/api-ingress` (older) |
| `/healthz`, `/web`, `/static` | one claimant each | trivial |

The rendered `00-default-server.conf` is byte-identical to the no-conflict case above. `team-a`'s `/api` still renders; `team-b`'s `/api` is silently omitted from the aggregate. `team-b/web-ingress` receives an event:

```
Warning  HostlessPathConflict  ingress/web-ingress  path /api lost arbitration to team-a/api-ingress (created 5m earlier)
```

`team-b`'s other paths (`/web`, `/static`) continue to render normally. The Ingress is partially active: non-conflicting paths serve traffic; conflicting paths are reported and suppressed. This matches ingress-nginx's behavior and follows NGIC's existing model for hosted-resource conflicts.

If `team-a/api-ingress` is later deleted, the next reconcile re-arbitrates: `team-b/web-ingress`'s `/api` becomes the sole claimant, the warning event is cleared, and `team-b`'s `/api` location appears in the rendered aggregate.

## Annotation Contract

The aggregate's server block is controller-owned. Server-level annotations are forbidden on Ingresses with any hostless rule. Location-level annotations are honored unchanged.

When `--allow-empty-ingress-host` is on and the Ingress has any rule with empty host, the following annotations cause `validateIngress` to return `field.Forbidden`:

| Annotation | Reason |
| --- | --- |
| `nginx.org/server-snippets` | Server-level emit. |
| `nginx.org/server-tokens` | Server-level emit. |
| `nginx.org/listen-ports` | Determines `listen` directive; conflicts with controller-owned ports. |
| `nginx.org/listen-ports-ssl` | Determines `listen` directive. |
| `nginx.org/redirect-to-https` | Server-level redirect logic. |
| `ingress.kubernetes.io/ssl-redirect` | Server-level redirect logic. |
| `nginx.org/hsts`, `hsts-max-age`, `hsts-include-subdomains`, `hsts-behind-proxy` | Server-level header injection. |
| `nginx.org/jwt-key`, `jwt-realm`, `jwt-token`, `jwt-login-url` | Server-level auth (Plus). |
| `nginx.com/jwt-key`, `jwt-realm`, `jwt-token`, `jwt-login-url` | Server-level auth (Plus). |
| `nginx.org/basic-auth-secret`, `basic-auth-realm` | Server-level auth. |
| `appprotect.f5.com/app-protect-policy` | Server-level WAF policy. |
| `appprotect.f5.com/app-protect-log-policy`, `app-protect-log-enable` | Server-level WAF logging. |
| `appprotectdos.f5.com/app-protect-dos-resource` | Server-level DOS protection. |
| `nginx.com/health-checks-mandatory`, `health-checks-mandatory-queue` | Server-level. |
| `nginx.org/app-root` | Server-level rewrite. |
| `nginx.org/mergeable-ingress-type` | Master/minion forbidden under hostless (separate aggregation model). |
| `nginx.org/proxy-buffering`, `proxy-buffer-size`, `proxy-buffers`, `proxy-max-temp-file-size` | Server-level when set without a path; allowed only when narrowed to a single location via NGIC's location-snippet mechanism. |
| `nginx.org/use-cluster-ip` | Server-level upstream behavior. |

The forbidden-annotation set is encoded as a table in `internal/k8s/validation.go` and exercised by table-driven tests. Any annotation added to NGIC after this design ships must be classified explicitly: a CI check enforces that every annotation handled by `validateIngressAnnotations` either appears in the forbidden table or is annotated with a `// hostless: location-only` marker comment indicating it is safe under hostless aggregation.

`spec.tls` and `spec.defaultBackend` are also forbidden on hostless Ingresses (already enforced by the PoC).

`kubernetes.io/ingress.class` and `ingressClassName` are honored unchanged: only Ingresses matching the controller's class participate in the aggregate.

## TLS Handling

The aggregate server uses the controller's default TLS configuration:

- `ssl_certificate` / `ssl_certificate_key` from `/etc/nginx/secrets/default` (the wildcard/default secret managed by the controller's `default-server-tls-secret` flag).
- `ssl_reject_handshake on;` if the controller is configured without a default certificate.

This matches the behavior of today's static default-server block. SNI mismatches and TLS handshakes for unknown servers fall through to the aggregate exactly as they do today.

`spec.tls` is forbidden on hostless Ingresses. Operators wanting a custom certificate for the catch-all server configure it via the existing `default-server-tls-secret` mechanism.

## File Ownership and Lifecycle

A single file `/etc/nginx/conf.d/00-default-server.conf` is owned by the controller. The `00-` prefix ensures NGINX loads it before per-Ingress files in lexicographic order, claiming the `default_server` listen role.

| State | `00-default-server.conf` |
| --- | --- |
| Flag off | Does not exist. Static block in `nginx.tmpl` provides the catch-all (today's behavior). |
| Flag on, no hostless Ingresses | Controller-generated synthetic catch-all (returns `DefaultServerReturn`, optional `/healthz` endpoint). |
| Flag on, ≥1 hostless Ingress | Aggregate of all contributing Ingresses, with locations from each member. |

The static default-server block is conditionally emitted in `nginx.tmpl` and `nginx-plus.tmpl`. When `--allow-empty-ingress-host` is on, the block is suppressed and the http-level template instead emits `map $http_host $resource_type { default ""; }` and friends so that location-level tracking variables resolve correctly when sourced from the aggregate.

`Configurator.syncHostlessAggregateConfig`:

- Walks `Configurator.ingresses`, collects those with `ValidHosts[""] == true`.
- If any: calls `generateNginxCfgForHostlessIngresses(members)`, executes the template, writes `00-default-server.conf`.
- If none: renders a controller-only synthetic catch-all (today's static-block contents, parameterized by `DefaultServerReturn`, `DefaultServerAccessLogOff`, `HealthStatus`, `HealthStatusURI`), writes `00-default-server.conf`.

`syncHostlessAggregateConfig` runs after every successful Ingress add/update/delete. Per-Ingress files (`<ns>-<name>.conf`) continue to be written for hosted rules. A single Ingress with both hosted and hostless rules has its hosted rules rendered into its per-Ingress file (as today) and its hostless rule contributed to the aggregate.

`Configurator.DeleteIngress` does not delete `00-default-server.conf` directly. It removes the Ingress from internal state, then calls `syncHostlessAggregateConfig`, which either rewrites the file with remaining members or replaces it with the synthetic fallback.

`generateNginxCfgForHostlessIngresses` output is byte-stable across reconciliations given the same cluster state, allowing `ConfigRollbackManager`'s skip-on-unchanged-content path to short-circuit `nginx -t` and `nginx -s reload` when no hostless Ingresses changed.

## Rendering

`generateNginxCfgForHostlessIngresses` lives next to `generateNginxCfgForMergeableIngresses` in `internal/configs/ingress.go` and shares its structure:

```go
type HostlessAggregateParams struct {
    members      []*IngressEx
    pathOwners   map[string]*networking.Ingress
    staticParams *StaticConfigParams
    cfgParams    *ConfigParams
    isPlus       bool
    // ... other shared params from NginxCfgParams
}

func generateNginxCfgForHostlessIngresses(
    ncp HostlessAggregateParams,
) (version1.IngressNginxConfig, Warnings) {
    server := buildSyntheticDefaultServer(ncp.staticParams, ncp.cfgParams)
    var locations []version1.Location
    var upstreams []version1.Upstream
    var maps []version2.Map
    warnings := newWarnings()

    for _, ingEx := range ncp.members {
        // Render only the empty-host rule of this Ingress, in minion-style
        // mode that emits locations and upstreams without server-level config.
        memberCfg, memberWarnings := generateNginxCfg(NginxCfgParams{
            ingEx:        ingEx,
            isMinion:     true,
            hostFilter:   emptyHost,
            staticParams: ncp.staticParams,
            // ... other params
        })
        warnings.Add(memberWarnings)

        // Filter to paths this Ingress won arbitration for.
        for _, srv := range memberCfg.Servers {
            for _, loc := range srv.Locations {
                if ncp.pathOwners[loc.Path] == ingEx.Ingress {
                    locations = append(locations, loc)
                }
            }
        }
        upstreams = append(upstreams, memberCfg.Upstreams...)
        maps = append(maps, memberCfg.Maps...)
    }

    server.Locations = locations
    return version1.IngressNginxConfig{
        Servers:                 []version1.Server{server},
        Upstreams:               upstreams,
        Maps:                    removeDuplicateMaps(maps),
        Ingress:                 syntheticAggregateIngressMeta(),
        DynamicSSLReloadEnabled: ncp.staticParams.DynamicSSLReload,
        StaticSSLPath:           ncp.staticParams.StaticSSLPath,
    }, warnings
}
```

`generateNginxCfg` gains a new `hostFilter string` parameter. When set, only rules with `rule.Host == hostFilter` are rendered. This lets a single Ingress with mixed hosted and hostless rules contribute its hostless rule to the aggregate without leaking its hosted rules.

`buildSyntheticDefaultServer` produces a `version1.Server` with `IsDefaultServer: true`, controller-owned listen ports, default TLS, `server_name _`, no `set $resource_*` tracking variables, and the controller's configured fallback location (`return DefaultServerReturn` if no member contributes a `/` path).

The PoC's existing `IsDefaultServer` flag, `HasRootLocation` flag, and template changes in `nginx.ingress.tmpl` / `nginx-plus.ingress.tmpl` are reused unchanged.

**Plus-conditional directives.** `status_zone _;` is emitted only on NGINX Plus (the OSS build does not parse `status_zone` and rejects the config at `nginx -t`). The renderer takes an `isPlus bool` and gates Plus-only directives on it. The PoC currently omits `status_zone` unconditionally; the production version reinstates it under the Plus gate.

## Validation

`validateIngress(ing, ..., allowEmptyHost)` in `internal/k8s/validation.go`:

When `allowEmptyHost == false`:
- Empty host on any rule → `field.Required` (today's behavior, unchanged).

When `allowEmptyHost == true`:
- At most one empty-host rule per Ingress. Second occurrence → `field.Duplicate`.
- If any rule has empty host:
  - `spec.tls` → `field.Forbidden`.
  - `spec.defaultBackend` → `field.Forbidden`.
  - Each annotation in the forbidden table → `field.Forbidden`.

A separate validator `validateHostlessIngress` encapsulates these checks and is invoked from `validateIngress` only when the flag is on and the spec has at least one hostless rule.

Path conflicts between hostless Ingresses are not validation errors. They surface at reconcile time as warnings on the losing Ingress, attached via the existing `IngressConfiguration.Warnings` mechanism (extended to flow through the synthetic aggregate to its losing members). `kubectl describe ingress <name>` shows: `Warning: path /api lost arbitration to other-ns/other-ingress (created earlier)`.

## Configuration Layer Changes

`Configuration.buildHostsAndResources` (`internal/k8s/configuration.go:1502`) is extended to handle hostless rules in a separate accumulator:

```go
var hostlessMembers []*networking.Ingress
hostlessPathClaims := make(map[string][]*networking.Ingress)

for _, key := range getSortedIngressKeys(c.ingresses) {
    ing := c.ingresses[key]
    if isMinion(ing) { continue }

    var hostedRules, hostlessRules []networking.IngressRule
    for _, rule := range ing.Spec.Rules {
        if rule.Host == "" {
            hostlessRules = append(hostlessRules, rule)
        } else {
            hostedRules = append(hostedRules, rule)
        }
    }

    // Existing hosted-rule arbitration via newHosts[rule.Host] / Wins().
    // (unchanged)

    if len(hostlessRules) > 0 && c.allowEmptyIngressHost {
        hostlessMembers = append(hostlessMembers, ing)
        for _, rule := range hostlessRules {
            for _, path := range rule.HTTP.Paths {
                key := pathKey(path)
                hostlessPathClaims[key] = append(hostlessPathClaims[key], ing)
            }
        }
    }
}

if len(hostlessMembers) > 0 {
    pathOwners := arbitrateHostlessPaths(hostlessPathClaims)
    aggregate := NewHostlessAggregateConfiguration(hostlessMembers, pathOwners)
    newHosts[""] = aggregate
    newResources[aggregate.GetKeyWithKind()] = aggregate
}
```

`arbitrateHostlessPaths` runs `chooseObjectMetaWinner` pairwise across each path's claimants, returning the winner per path.

`updateActiveHostsForIngresses` (line 1127) is extended: for each Ingress in the aggregate's members, set `IngressEx.ValidHosts[""] = true` if at least one of its paths won arbitration; otherwise `false` and emit a warning that all of its hostless paths lost.

`detectChangesInHosts` requires no change. Empty string is a valid map key and the existing host-change detection naturally handles its add/remove/update events.

## Templates

The per-Ingress server template (`internal/configs/version1/nginx.ingress.tmpl`, `nginx-plus.ingress.tmpl`) gains the PoC's `IsDefaultServer` flag, which emits `default_server` on `listen`, `server_name _;`, suppresses per-Ingress `set $resource_*` tracking, conditionally emits `access_log off`, the health-status location, and a fallback `location /` (only when `HasRootLocation == false`). These changes are unchanged from PR #9614.

The http-level templates (`nginx.tmpl`, `nginx-plus.tmpl`) gain a conditional around the static default-server block. When `--allow-empty-ingress-host` is off, the block is emitted as today. When on, the block is suppressed and the following maps are added so location-level resource tracking variables resolve when sourced from the aggregate:

```nginx
map $http_upgrade $default_connection_header { default ""; }
map $http_host $resource_type { default ""; }
map $http_host $resource_name { default ""; }
map $http_host $resource_namespace { default ""; }
map $http_host $service { default ""; }
```

These maps are necessary because per-Ingress server blocks today set `$resource_*` directly, but when a request hits the aggregate's catch-all server it may match a location that expects those variables to exist as global defaults.

## Multi-Replica Behavior

The aggregate is a deterministic function of cluster state: the set of hostless Ingresses, their creation timestamps, and their UIDs. All NIC replicas observing the same cluster state converge on the same `00-default-server.conf` content and the same arbitration outcomes. Standard NIC replication semantics apply; no new replication concerns are introduced.

Replicas may transiently disagree during a rolling upgrade where the binary version differs across replicas (e.g., one replica is on a version with the flag absent and one with it on). This is consistent with how NIC handles other config flag transitions today.

## Interaction with Existing Features

- **Mergeable ingresses (`master`/`minion`).** `nginx.org/mergeable-ingress-type` is forbidden on Ingresses with any hostless rule. A hostless Ingress cannot be a master or minion. Hosted Ingresses continue using mergeable-ingresses unchanged.
- **VirtualServer / VirtualServerRoute.** Unaffected. VS/VSR do not interact with the catch-all server. A future revision may extend hostless support to VS via the `poc/vsr-no-host` branch's exploration; out of scope here.
- **TLS Passthrough.** The aggregate listens on the standard SSL socket. The TLS Passthrough socket (`unix:/var/lib/nginx/passthrough-https.sock`) is independent and continues to work unchanged. A hostless Ingress cannot enable TLS Passthrough.
- **OIDC.** Forbidden on hostless (server-level feature; relies on JWT validation at the server scope).
- **App Protect, App Protect DOS.** Forbidden on hostless (server-level WAF/DOS attachment).
- **Wildcard host vs. empty host.** An Ingress with `host: "*.example.com"` lives at NGINX's wildcard server tier, distinct from `default_server`. Requests for `foo.example.com` hit the wildcard server; requests with no Host header or an unmatched Host header hit the empty-host aggregate. Consistent with ingress-nginx and with NGINX's own `server_name` matching rules.
- **Ingress class filtering.** Applied before aggregation. Only Ingresses matching the controller's `--ingress-class` (or `ingressClassName`) participate.
- **Snippets feature flag.** When `--enable-snippets` is off, `nginx.org/server-snippets` is already forbidden globally. The hostless forbidden-annotation entry is redundant in that case but harmless.

## Migration

- **Default off.** `--allow-empty-ingress-host=false` is the default. No existing deployment changes behavior on upgrade.
- **Turning the flag on.** Operators who set the flag and apply hostless Ingresses see `00-default-server.conf` appear in `/etc/nginx/conf.d/`, replacing the static default-server block previously embedded in the main config. Behavior for existing hosted Ingresses is unchanged.
- **Turning the flag off.** Requires that no Ingress in the cluster have an empty-host rule. Such rules will be rejected by validation on the next reconcile, leaving the cluster in a partially-rejected state until the rules are removed. Operators downgrading should remove hostless Ingresses before flipping the flag.
- **CRD impact.** None. Works on standard `networking.k8s.io/v1` Ingress.
- **Helm/manifest impact.** New flag `--allow-empty-ingress-host` documented in `cmd/nginx-ingress/flags.go`. Helm chart adds an opt-in value `controller.allowEmptyIngressHost` (default false).

## Open Questions

- **`spec.defaultBackend` support.** The Kubernetes spec also permits an Ingress with `spec.defaultBackend` and no rules. This design forbids it on hostless Ingresses. A future revision may allow exactly one Ingress in the cluster to define the catch-all `/` location via `defaultBackend`, replacing the controller-emitted fallback. This requires its own arbitration model (one winner, no path merging) and is left out of scope.
- **Path conflict surfacing.** Today's `Warnings` field on `IngressConfiguration` is per-resource. The aggregate's path conflicts attach to losing Ingresses through `IngressEx.ValidHosts[""] == false`, but a richer `kubectl get ingress` status condition (`HostlessPathConflict`, with the winning resource's namespace/name) would improve operator visibility. Not blocking.
- **Cert lifecycle for the catch-all.** The default secret is controller-owned. Operators wanting a real certificate for the catch-all (for browsers visiting by IP) configure it via `--default-server-tls-secret`. No declarative per-Ingress override is offered. If demand arises, a future revision could allow exactly one hostless Ingress to designate the catch-all certificate via a dedicated annotation. That one resource benefits from PR #9614's original single-claim model, alongside the path-level aggregation this design provides.
- **Annotation classification CI.** The forbidden-annotation table requires ongoing maintenance as new annotations are added to NGIC. The proposed marker comment (`// hostless: location-only`) plus a `go vet`-style check is one approach; a more robust alternative is to gate the flag on a per-annotation capability registry (deeper refactor).
- **Mergeable hostless.** A future revision could allow hostless Ingresses to participate in master/minion themselves (an explicit master Ingress with no host, accepting minions). This would let one Ingress control server-level configuration of the catch-all while N minions contribute paths. Out of scope; revisit if user demand for shared server-level configuration on the catch-all materializes.
- **Endpoint update propagation.** `Configurator.UpdateEndpoints` updates upstream membership (via the NGINX Plus dynamic upstream API on Plus, file rewrite + reload on OSS) without going through `addOrUpdateIngress`. The aggregator hook is on `addOrUpdateIngress`, so endpoint-only changes for hostless backends do not regenerate `00-default-server.conf`. The PoC sidesteps this because the demo applies Ingresses after their backends are ready: endpoints are present at first reconcile. In production with rolling backend deploys, the aggregate would carry stale endpoint IPs until the next full Ingress reconcile (configmap change, Ingress edit, controller restart). Fix: add a parallel hook on `UpdateEndpoints` that calls `syncHostlessAggregateConfig` when any updated endpoint slice belongs to a service referenced by a hostless Ingress. Required before production.
- **Plus-only directives.** The aggregate currently omits `status_zone` (Plus-only). The full design includes Plus-conditional emission of `status_zone _;` so Plus's per-server status reporting works for the catch-all. The renderer needs an `isPlus` parameter; trivial follow-up.
- **Aggregator debouncing.** Under Option 2 (synthetic events), the aggregator runs N times per batch with N hostless Ingresses. Each run rewrites `00-default-server.conf` with progressively more members. The `ConfigRollbackManager`'s skip-on-unchanged-content path filters most of the redundant disk writes, but the final reload still happens. Debouncing the aggregator to once per batch (via a "pending sync" flag flushed at end-of-batch) is a quality-of-implementation improvement worth doing before scale-testing.

## PoC Validation

A minimal PoC implementing Option 2 (synthetic events) was deployed to a kind cluster with two hostless Ingresses across `team-a` and `team-b` namespaces. Verified:

- Both Ingresses accepted by validation; neither rejected as "all hosts taken".
- `/etc/nginx/conf.d/00-default-server.conf` rendered with one `server { listen 80 default_server; ... }` block, two upstreams with real pod IPs (e.g., `server 10.244.0.6:8080 ...`), two locations with per-location `set $resource_namespace`/`$resource_name` attribution, and a synthesised `location / { return 404; }` fallback.
- Per-Ingress files (`team-a-api-ingress.conf`, `team-b-web-ingress.conf`) contain only the comment header; empty-host rules deliberately suppressed in `generateNginxCfg`.
- `nginx -t` passes inside the controller pod.
- `curl http://<svc>/api` → `hello from team-a /api`.
- `curl http://<svc>/web` → `hello from team-b /web`.
- `curl http://<svc>/unknown` → 404 from the synthesised fallback.
- `curl -H 'Host: bogus.example.invalid' http://<svc>/api` → routes to team-a (catch-all behaviour through `default_server`).

Branch: `poc/empty-host-aggregation`, commits `ee6c8a053` (initial) + `9705b3b12` (demo fixes).

Bugs the PoC surfaced that pure-renderer unit tests missed (now fixed in commit `9705b3b12`, documented in this proposal):

1. Hostless Ingresses rejected by `addProblemsForResourcesWithoutActiveHost` because `ValidHosts[""] = false`.
2. Change detection is host-keyed; without registering empty host as a host slot, no events fire. Solved with synthetic events (Option 2 above).
3. `createIngressEx` skips endpoint resolution for rules where `!validHosts[rule.Host]`, leaving the aggregate with placeholder upstream addresses.
4. `status_zone` is Plus-only and breaks `nginx -t` on OSS.

## Reproducing the PoC

Assumes `kind`, `docker`, and `kubectl` are installed, and the working directory is the repository root.

### 0. Create a kind cluster with port mappings

Kind clusters run inside a Docker container with their own network namespace, so NodePort services are not reachable from the host by default. The standard fix is `extraPortMappings` at cluster-create time, paired with `hostPort` on the controller container later. This avoids needing a port-forward at curl time.

```yaml
# /tmp/kind.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - { containerPort: 80,  hostPort: 8080, protocol: TCP }
  - { containerPort: 443, hostPort: 8443, protocol: TCP }
```

```bash
kind create cluster --config /tmp/kind.yaml
kubectl cluster-info --context kind-kind
```

If you have multiple kind clusters, note the cluster name; subsequent `kind load` invocations default to the cluster named `kind` and accept `--name <cluster>` to target a specific one. Recreating an existing cluster requires `kind delete cluster` first.

### 1. Check out the PoC branch and build the OSS image

The Makefile defaults to `ARCH=amd64`. On Apple Silicon Macs (or any arm64 host), the kind node is arm64 and an amd64 image will load successfully but kubelet will report `ErrImageNeverPull` because containerd refuses to use a platform-mismatched image. Set `ARCH` to match your host:

```bash
git checkout poc/empty-host-aggregation
HOST_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
ARCH=$HOST_ARCH TARGET=local make debian-image
```

The build produces `nginx/nginx-ingress:5.5.0-SNAPSHOT` (tag derived from `.github/data/version.txt`).

Verify the image exists in your local Docker daemon and matches the host architecture:

```bash
docker image inspect nginx/nginx-ingress:5.5.0-SNAPSHOT \
  --format '{{.Architecture}} {{.Os}}'
# arm64 linux   (or amd64 linux on Intel/AMD hosts)
```

### 2. Load the image into kind

```bash
kind load docker-image nginx/nginx-ingress:5.5.0-SNAPSHOT
```

If you have multiple kind clusters, pass `--name <cluster>` to target the right one. Verify the image is present on the node:

```bash
docker exec -it kind-control-plane crictl images | grep nginx-ingress
# docker.io/nginx/nginx-ingress     5.5.0-SNAPSHOT     ...
```

### 3. Apply the prerequisite manifests

```bash
kubectl apply -f deployments/common/ns-and-sa.yaml
kubectl apply -f deployments/rbac/rbac.yaml
kubectl apply -f deployments/common/nginx-config.yaml
kubectl apply -f deployments/common/ingress-class.yaml
kubectl apply -f config/crd/bases/
```

### 4. Deploy the controller with the feature flag

The stock deployment manifest does not include `--allow-empty-ingress-host`. Apply this minimal version that does (saved as `/tmp/controller.yaml` or anywhere else):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-ingress
  namespace: nginx-ingress
spec:
  replicas: 1
  # Recreate (not RollingUpdate) so iteration via `rollout restart` works:
  # the controller binds the kind node's host ports 80/443 via hostPort,
  # so a second replica cannot start alongside the old one.
  strategy:
    type: Recreate
  selector:
    matchLabels: { app: nginx-ingress }
  template:
    metadata:
      labels: { app: nginx-ingress }
    spec:
      serviceAccountName: nginx-ingress
      # Tolerate the control-plane taint in case the kind cluster has one
      # (single-node kind clusters typically don't, but multi-node configs
      # and some kind versions briefly do during startup).
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Equal
        effect: NoSchedule
      containers:
      - name: nginx-ingress
        image: nginx/nginx-ingress:5.5.0-SNAPSHOT
        imagePullPolicy: Never
        ports:
        # hostPort binds the controller directly to the kind node's port,
        # which the kind cluster config maps to localhost:8080 / :8443.
        - { name: http, containerPort: 80,   hostPort: 80 }
        - { name: https, containerPort: 443, hostPort: 443 }
        - { name: readiness-port, containerPort: 8081 }
        readinessProbe:
          httpGet: { path: /nginx-ready, port: readiness-port }
          periodSeconds: 1
        securityContext:
          allowPrivilegeEscalation: true
          runAsUser: 101
          runAsNonRoot: true
          capabilities:
            drop: [ALL]
            add: [NET_BIND_SERVICE]
        env:
        - name: POD_NAMESPACE
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - name: POD_NAME
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
        args:
          - -nginx-configmaps=$(POD_NAMESPACE)/nginx-config
          - -ingress-class=nginx
          - -allow-empty-ingress-host
          - -log-level=debug
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-ingress
  namespace: nginx-ingress
spec:
  type: ClusterIP
  selector: { app: nginx-ingress }
  ports:
  - { name: http, port: 80, targetPort: 80 }
  - { name: https, port: 443, targetPort: 443 }
```

```bash
kubectl apply -f /tmp/controller.yaml
kubectl -n nginx-ingress rollout status deploy/nginx-ingress --timeout=60s
```

If the rollout never completes and `kubectl describe pod` shows `ErrImageNeverPull`, the image you loaded is the wrong architecture for the kind node. Rebuild with `ARCH` matching the host (step 1) and re-run `kind load`.

### 5. Apply two hostless Ingresses across two namespaces

The Worked Example section above shows the Ingresses. Use this fuller manifest, which also includes the backend Deployments and Services:

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: team-a }
---
apiVersion: v1
kind: Namespace
metadata: { name: team-b }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: team-a }
spec:
  replicas: 1
  selector: { matchLabels: { app: api } }
  template:
    metadata: { labels: { app: api } }
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=hello from team-a /api", "-listen=:8080"]
        ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: api-svc, namespace: team-a }
spec:
  selector: { app: api }
  ports: [{ port: 8080, targetPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: api-ingress, namespace: team-a }
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port: { number: 8080 }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: team-b }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args: ["-text=hello from team-b /web", "-listen=:8080"]
        ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: web-svc, namespace: team-b }
spec:
  selector: { app: web }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: web-ingress, namespace: team-b }
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /web
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port: { number: 80 }
```

```bash
kubectl apply -f /tmp/workloads.yaml
kubectl -n team-a wait --for=condition=ready pod -l app=api --timeout=60s
kubectl -n team-b wait --for=condition=ready pod -l app=web --timeout=60s
```

### 6. Verify the rendered aggregate and run nginx -t

```bash
kubectl -n nginx-ingress exec deploy/nginx-ingress -- ls -la /etc/nginx/conf.d/
kubectl -n nginx-ingress exec deploy/nginx-ingress -- cat /etc/nginx/conf.d/00-default-server.conf
kubectl -n nginx-ingress exec deploy/nginx-ingress -- nginx -t
```

The aggregate should contain one `server { ... default_server ... }` block, two upstreams with real pod IPs, and two locations (`/api` and `/web`). The per-Ingress files (`team-a-api-ingress.conf`, `team-b-web-ingress.conf`) contain only the comment header.

### 7. Curl through the aggregate

The controller binds directly to the kind node's port 80 via `hostPort`; the cluster config's `extraPortMappings` then exposes that as `localhost:8080` on your machine. No port-forward needed.

```bash
curl -s http://localhost:8080/api
# hello from team-a /api

curl -s http://localhost:8080/web
# hello from team-b /web

curl -s -i http://localhost:8080/unknown | head -1
# HTTP/1.1 404 Not Found

curl -s -H 'Host: bogus.example.invalid' http://localhost:8080/api
# hello from team-a /api  (default_server catches the unknown Host)
```

### 8. (Optional) Iterate on the code

After editing source, rebuild the image, reload it into kind, and restart the deployment:

```bash
TARGET=local make debian-image
kind load docker-image nginx/nginx-ingress:5.5.0-SNAPSHOT
kubectl -n nginx-ingress rollout restart deploy/nginx-ingress
kubectl -n nginx-ingress rollout status deploy/nginx-ingress --timeout=60s
```

## Effort Estimate

| Area | Source LOC | Test LOC |
| --- | --- | --- |
| `internal/k8s/configuration.go` (aggregate type, `buildHostsAndResources` extension, path arbitration) | ~250 | ~400 |
| `internal/configs/ingress.go` (`generateNginxCfgForHostlessIngresses`, `hostFilter` plumbing in `generateNginxCfg`) | ~300 | ~500 |
| `internal/configs/configurator.go` (`syncHostlessAggregateConfig`, file lifecycle, generalisation of PR #9614's single-claim sync) | ~120 | ~200 |
| `internal/k8s/validation.go` (forbidden-annotation table, `validateHostlessIngress`, marker-comment audit) | ~300 | ~500 |
| Templates (`nginx.tmpl`, `nginx-plus.tmpl`, `nginx.ingress.tmpl`, `nginx-plus.ingress.tmpl`) | ~80 | covered in ingress.go tests |
| E2E tests (`tests/`): cross-namespace merge, oldest-wins, path conflicts, flag-toggle, mergeable-interaction, deletion ordering | n/a | ~700 |
| Documentation (Helm chart values, flag reference, hostless usage guide) | ~150 | n/a |

Total: ~1200 lines source + ~2300 lines tests, comparable to the current `feat/empty-host-ingress` branch (PR #9728: +4528 / -2954 across 46 files).

The work is incremental on top of PR #9614: the synthetic file slot, `IsDefaultServer` flag, validation hooks, and template changes all carry over. The new work is the aggregation path through `Configuration` and `Configurator`, plus the forbidden-annotation audit.

## Acceptance Criteria

- Two hostless Ingresses in different namespaces with non-conflicting paths both serve traffic via the catch-all.
- Two hostless Ingresses with conflicting paths: oldest wins, loser's path is suppressed, loser receives a `kubectl events` warning naming the winner.
- Deleting the winning Ingress causes the path to be re-arbitrated (the next-oldest claimant's path is rendered).
- Deleting all hostless Ingresses restores the controller-emitted synthetic catch-all.
- Toggling `--allow-empty-ingress-host=false` on a cluster with hostless Ingresses rejects them on next reconcile, leaves hosted Ingresses untouched.
- Per-Ingress server-level annotations on a hostless Ingress are rejected with `field.Forbidden`.
- A single Ingress with both hosted and hostless rules: hosted rules render to its per-Ingress file, hostless rule contributes to the aggregate, both work simultaneously.
- `nginx -t` passes after every reconcile across all the above scenarios.
- E2E test suite covers cross-namespace merge, path conflict resolution, mergeable-ingress interaction, deletion ordering, flag-toggle behavior, and deterministic rendering.
