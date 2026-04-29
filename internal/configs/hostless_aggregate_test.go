package configs

import (
	"strings"
	"testing"
)

// TestRenderHostlessAggregate_TwoIngressesAcrossNamespaces verifies the
// shape of the rendered output when two hostless Ingresses in different
// namespaces both contribute paths.
func TestRenderHostlessAggregate_TwoIngressesAcrossNamespaces(t *testing.T) {
	t.Parallel()
	static := &StaticConfigParams{
		AllowEmptyIngressHost:    true,
		DefaultHTTPListenerPort:  80,
		DefaultHTTPSListenerPort: 443,
		DisableIPV6:              false,
		SSLRejectHandshake:       false,
	}
	cfg := &ConfigParams{
		MaxFails:            1,
		FailTimeout:         "10s",
		DefaultServerReturn: "404",
	}
	upstreams := []hostlessUpstream{
		{name: "team-a-api-ingress-_-api-svc-8080", servers: []string{"10.244.1.5:8080", "10.244.1.6:8080"}},
		{name: "team-b-web-ingress-_-web-svc-80", servers: []string{"10.244.2.4:80"}},
	}
	locations := []hostlessLocation{
		{path: "/api", upstreamName: "team-a-api-ingress-_-api-svc-8080", namespace: "team-a", ingressName: "api-ingress", serviceName: "api-svc"},
		{path: "/web", upstreamName: "team-b-web-ingress-_-web-svc-80", namespace: "team-b", ingressName: "web-ingress", serviceName: "web-svc"},
	}

	out := renderHostlessAggregate(static, cfg, upstreams, locations)

	checks := []string{
		// listen directives with default_server on both v4 and v6, both ports
		"listen 80 default_server;",
		"listen [::]:80 default_server;",
		"listen 443 ssl default_server;",
		"listen [::]:443 ssl default_server;",
		// the synthetic server_name catches anything unmatched
		"server_name _;",
		// both upstreams present with their endpoint IPs
		"upstream team-a-api-ingress-_-api-svc-8080",
		"server 10.244.1.5:8080",
		"server 10.244.1.6:8080",
		"upstream team-b-web-ingress-_-web-svc-80",
		"server 10.244.2.4:80",
		// both locations, with per-location resource attribution
		"location /api {",
		`set $resource_namespace   "team-a"`,
		`set $resource_name        "api-ingress"`,
		"proxy_pass http://team-a-api-ingress-_-api-svc-8080;",
		"location /web {",
		`set $resource_namespace   "team-b"`,
		`set $resource_name        "web-ingress"`,
		"proxy_pass http://team-b-web-ingress-_-web-svc-80;",
		// synthesised fallback (neither member claims "/")
		"location / {",
		"return 404;",
	}
	for _, want := range checks {
		if !strings.Contains(out, want) {
			t.Errorf("rendered aggregate missing %q\n--- output ---\n%s", want, out)
		}
	}

	// Exactly one default_server claim per address:port (NGINX hard limit).
	if got := strings.Count(out, " default_server"); got != 4 {
		t.Errorf("expected 4 default_server occurrences (v4+v6 × http+https), got %d", got)
	}
}

// TestRenderHostlessAggregate_NoMembersEmitsFallback verifies the synthetic
// fallback when the flag is on but no Ingress contributes paths — NGINX still
// needs a default_server somewhere on each port.
func TestRenderHostlessAggregate_NoMembersEmitsFallback(t *testing.T) {
	t.Parallel()
	static := &StaticConfigParams{
		AllowEmptyIngressHost:    true,
		DefaultHTTPListenerPort:  80,
		DefaultHTTPSListenerPort: 443,
	}
	cfg := &ConfigParams{DefaultServerReturn: "404"}

	out := renderHostlessAggregate(static, cfg, nil, nil)

	for _, want := range []string{
		"listen 80 default_server;",
		"server_name _;",
		"location / {",
		"return 404;",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("fallback aggregate missing %q\n--- output ---\n%s", want, out)
		}
	}
}

// TestRenderHostlessAggregate_RootPathSuppressesSyntheticFallback verifies
// that when a member contributes a "/" location, the synthetic fallback is
// suppressed (avoids two location / blocks).
func TestRenderHostlessAggregate_RootPathSuppressesSyntheticFallback(t *testing.T) {
	t.Parallel()
	static := &StaticConfigParams{
		AllowEmptyIngressHost:    true,
		DefaultHTTPListenerPort:  80,
		DefaultHTTPSListenerPort: 443,
	}
	cfg := &ConfigParams{MaxFails: 1, FailTimeout: "10s", DefaultServerReturn: "404"}
	upstreams := []hostlessUpstream{
		{name: "ns-app-_-svc-80", servers: []string{"10.0.0.1:80"}},
	}
	locations := []hostlessLocation{
		{path: "/", upstreamName: "ns-app-_-svc-80", namespace: "ns", ingressName: "app", serviceName: "svc"},
	}

	out := renderHostlessAggregate(static, cfg, upstreams, locations)

	if got := strings.Count(out, "location / {"); got != 1 {
		t.Errorf("expected exactly 1 'location / {' (member's, no synthetic fallback), got %d", got)
	}
	if strings.Contains(out, "return 404;") {
		t.Errorf("synthetic fallback should be suppressed when member claims /")
	}
}
