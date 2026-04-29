package configs

import (
	"fmt"
	"sort"
	"strings"

	networking "k8s.io/api/networking/v1"
)

// hostlessAggregateConfigName is the on-disk filename (without extension) for
// the rendered hostless aggregate. The "00-" prefix ensures NGINX loads it
// before any per-Ingress conf.d file, so it claims the default_server slot.
const hostlessAggregateConfigName = "00-default-server"

// hostlessLocation describes a single rendered location contributed to the
// aggregate by a member Ingress.
type hostlessLocation struct {
	path         string
	pathType     string
	upstreamName string
	namespace    string
	ingressName  string
	serviceName  string
}

// hostlessUpstream describes an upstream block in the rendered aggregate.
// Server addresses are pre-resolved endpoint IPs sourced from IngressEx.Endpoints.
type hostlessUpstream struct {
	name    string
	servers []string
}

// syncHostlessAggregateConfig (re)renders the cluster-wide hostless aggregate
// to /etc/nginx/conf.d/00-default-server.conf when --allow-empty-ingress-host
// is on. It walks Configurator.ingresses, gathers all rules with empty host,
// and emits a single server block with merged locations and upstreams.
//
// Path conflicts are resolved deterministically by Ingress sort order
// (namespace/name); a follow-up will replace this with chooseObjectMetaWinner.
//
// When the flag is on but no hostless Ingresses exist, a synthetic catch-all
// is written that mirrors the static default-server's previous behaviour
// (returns DefaultServerReturn, optional /healthz endpoint).
func (cnf *Configurator) syncHostlessAggregateConfig() error {
	if !cnf.staticCfgParams.AllowEmptyIngressHost {
		return nil
	}

	upstreams, locations := cnf.collectHostlessMembers()
	content := renderHostlessAggregate(cnf.staticCfgParams, cnf.CfgParams, upstreams, locations)
	if _, err := cnf.nginxManager.CreateConfig(hostlessAggregateConfigName, []byte(content)); err != nil {
		return fmt.Errorf("error writing hostless aggregate config: %w", err)
	}
	return nil
}

// collectHostlessMembers walks cnf.ingresses (sorted by key for stable output)
// and returns the upstreams and locations contributed by all hostless rules.
//
// Path conflict resolution: the first claimant wins, where ordering is
// deterministic via the sorted Ingress key. Later claimants are dropped.
func (cnf *Configurator) collectHostlessMembers() ([]hostlessUpstream, []hostlessLocation) {
	keys := make([]string, 0, len(cnf.ingresses))
	for k := range cnf.ingresses {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var upstreams []hostlessUpstream
	var locations []hostlessLocation
	seenPaths := make(map[string]string) // path -> "<ns>/<name>" of winner
	seenUpstreams := make(map[string]bool)

	for _, key := range keys {
		ingEx := cnf.ingresses[key]
		if ingEx == nil {
			continue
		}
		ing := ingEx.Ingress

		for _, rule := range ing.Spec.Rules {
			if rule.Host != "" || rule.HTTP == nil {
				continue
			}
			for _, p := range rule.HTTP.Paths {
				if p.Backend.Service == nil {
					continue
				}
				path := p.Path
				if existing, taken := seenPaths[path]; taken {
					_ = existing // path conflict; drop this claim. Surfaced as a warning in a follow-up.
					continue
				}
				seenPaths[path] = ing.Namespace + "/" + ing.Name

				upstreamName := getNameForUpstream(ing, "_", &p.Backend)
				if !seenUpstreams[upstreamName] {
					endpointKey := p.Backend.Service.Name + GetBackendPortAsString(p.Backend.Service.Port)
					servers := ingEx.Endpoints[endpointKey]
					upstreams = append(upstreams, hostlessUpstream{
						name:    upstreamName,
						servers: servers,
					})
					seenUpstreams[upstreamName] = true
				}

				locations = append(locations, hostlessLocation{
					path:         path,
					pathType:     pathTypeString(p.PathType),
					upstreamName: upstreamName,
					namespace:    ing.Namespace,
					ingressName:  ing.Name,
					serviceName:  p.Backend.Service.Name,
				})
			}
		}
	}

	return upstreams, locations
}

// pathTypeString returns "= " (Exact) or "" (Prefix / unset). Suitable for
// embedding directly into `location <prefix>{{.path}}`.
func pathTypeString(pt *networking.PathType) string {
	if pt != nil && *pt == networking.PathTypeExact {
		return "= "
	}
	return ""
}

// renderHostlessAggregate builds the full conf.d file as a string. Hand-written
// rather than going through the Go template engine — the aggregate is small and
// regular enough that a string builder is clearer than wiring a new template.
func renderHostlessAggregate(
	static *StaticConfigParams,
	cfg *ConfigParams,
	upstreams []hostlessUpstream,
	locations []hostlessLocation,
) string {
	var b strings.Builder

	for _, u := range upstreams {
		fmt.Fprintf(&b, "upstream %s {\n", u.name)
		fmt.Fprintf(&b, "    zone %s 256k;\n", u.name)
		if len(u.servers) == 0 {
			// No endpoints yet — point at the dummy address so nginx -t passes
			// and the upstream returns 502 until endpoints arrive.
			fmt.Fprintf(&b, "    server 127.0.0.1:8181 max_fails=1 fail_timeout=10s;\n")
		} else {
			sortedServers := append([]string(nil), u.servers...)
			sort.Strings(sortedServers)
			for _, s := range sortedServers {
				fmt.Fprintf(&b, "    server %s max_fails=%d fail_timeout=%s;\n",
					s, cfg.MaxFails, cfg.FailTimeout)
			}
		}
		b.WriteString("}\n\n")
	}

	b.WriteString("server {\n")
	fmt.Fprintf(&b, "    listen %d default_server;\n", static.DefaultHTTPListenerPort)
	if !static.DisableIPV6 {
		fmt.Fprintf(&b, "    listen [::]:%d default_server;\n", static.DefaultHTTPListenerPort)
	}
	fmt.Fprintf(&b, "    listen %d ssl default_server;\n", static.DefaultHTTPSListenerPort)
	if !static.DisableIPV6 {
		fmt.Fprintf(&b, "    listen [::]:%d ssl default_server;\n", static.DefaultHTTPSListenerPort)
	}
	b.WriteString("\n")
	b.WriteString("    server_name _;\n")
	// status_zone is Plus-only; omitted from this PoC.

	if static.SSLRejectHandshake {
		b.WriteString("    ssl_reject_handshake on;\n")
	} else {
		b.WriteString("    ssl_certificate /etc/nginx/secrets/default;\n")
		b.WriteString("    ssl_certificate_key /etc/nginx/secrets/default;\n")
	}
	b.WriteString("\n")

	if cfg != nil && cfg.DefaultServerAccessLogOff {
		b.WriteString("    access_log off;\n")
	}
	if static.HealthStatus {
		fmt.Fprintf(&b, "    location = %s {\n", static.HealthStatusURI)
		b.WriteString("        default_type text/plain;\n")
		b.WriteString("        return 200 \"healthy\\n\";\n")
		b.WriteString("    }\n\n")
	}

	hasRoot := false
	for _, loc := range locations {
		if loc.path == "/" {
			hasRoot = true
		}
		fmt.Fprintf(&b, "    location %s%s {\n", loc.pathType, loc.path)
		fmt.Fprintf(&b, "        set $service              %q;\n", loc.serviceName)
		fmt.Fprintf(&b, "        set $resource_type        \"ingress\";\n")
		fmt.Fprintf(&b, "        set $resource_name        %q;\n", loc.ingressName)
		fmt.Fprintf(&b, "        set $resource_namespace   %q;\n", loc.namespace)
		b.WriteString("\n")
		b.WriteString("        proxy_http_version 1.1;\n")
		b.WriteString("        proxy_set_header Host              $host;\n")
		b.WriteString("        proxy_set_header X-Real-IP         $remote_addr;\n")
		b.WriteString("        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;\n")
		b.WriteString("        proxy_set_header X-Forwarded-Proto $scheme;\n")
		fmt.Fprintf(&b, "        proxy_pass http://%s;\n", loc.upstreamName)
		b.WriteString("    }\n\n")
	}

	if !hasRoot {
		// Synthesised fallback — mirrors the controller's DefaultServerReturn
		// behaviour from the previous static block.
		ret := "404"
		if cfg != nil && cfg.DefaultServerReturn != "" {
			ret = cfg.DefaultServerReturn
		}
		fmt.Fprintf(&b, "    location / {\n        return %s;\n    }\n", ret)
	}

	b.WriteString("}\n")
	return b.String()
}
