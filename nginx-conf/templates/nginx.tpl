nginx.tmpl 
# nginx-proxy{{ if $.Env.NGINX_PROXY_VERSION }} version : {{ $.Env.NGINX_PROXY_VERSION }}{{ end }}

{{- /*
     * Global values.  Values are stored in this map rather than in individual
     * global variables so that the values can be easily passed to embedded
     * templates.  (Go templates cannot access variables outside of their own
     * scope.)
     */}}
{{- $globals := dict }}
{{- $_ := set $globals "containers" $ }}
{{- $_ := set $globals "Env" $.Env }}
{{- $_ := set $globals "Docker" $.Docker }}
{{- $_ := set $globals "CurrentContainer" (where $globals.containers "ID" $globals.Docker.CurrentContainerID | first) }}
{{- $_ := set $globals "default_cert_ok" (and (exists "/etc/nginx/certs/default.crt") (exists "/etc/nginx/certs/default.key")) }}
{{- $_ := set $globals "external_http_port" (coalesce $globals.Env.HTTP_PORT "80") }}
{{- $_ := set $globals "external_https_port" (coalesce $globals.Env.HTTPS_PORT "443") }}
{{- $_ := set $globals "sha1_upstream_name" (parseBool (coalesce $globals.Env.SHA1_UPSTREAM_NAME "false")) }}
{{- $_ := set $globals "default_root_response" (coalesce $globals.Env.DEFAULT_ROOT "404") }}
{{- $_ := set $globals "trust_downstream_proxy" (parseBool (coalesce $globals.Env.TRUST_DOWNSTREAM_PROXY "true")) }}
{{- $_ := set $globals "access_log" (or (and (not $globals.Env.DISABLE_ACCESS_LOGS) "access_log /var/log/nginx/access.log vhost;") "") }}
{{- $_ := set $globals "enable_ipv6" (parseBool (coalesce $globals.Env.ENABLE_IPV6 "false")) }}
{{- $_ := set $globals "ssl_policy" (or ($globals.Env.SSL_POLICY) "Mozilla-Intermediate") }}
{{- $_ := set $globals "vhosts" (dict) }}
{{- $_ := set $globals "networks" (dict) }}
# Networks available to the container running docker-gen (which are assumed to
# match the networks available to the container running nginx):
{{- /*
     * Note: $globals.CurrentContainer may be nil in some circumstances due to
     * <https://github.com/nginx-proxy/docker-gen/issues/458>.  For more context
     * see <https://github.com/nginx-proxy/nginx-proxy/issues/2189>.
     */}}
{{- if $globals.CurrentContainer }}
    {{- range sortObjectsByKeysAsc $globals.CurrentContainer.Networks "Name" }}
        {{- $_ := set $globals.networks .Name . }}
#     {{ .Name }}
    {{- else }}
#     (none)
    {{- end }}
{{- else }}
# /!\ WARNING: Failed to find the Docker container running docker-gen.  All
#              upstream (backend) application containers will appear to be
#              unreachable.  Try removing the -only-exposed and -only-published
#              arguments to docker-gen if you pass either of those.  See
#              <https://github.com/nginx-proxy/docker-gen/issues/458>.
{{- end }}

{{- /*
     * Template used as a function to get a container's IP address.  This
     * template only outputs debug comments; the IP address is "returned" by
     * storing the value in the provided dot dict.
     *
     * The provided dot dict is expected to have the following entries:
     *   - "globals": Global values.
     *   - "container": The container's RuntimeContainer struct.
     *
     * The return value will be added to the dot dict with key "ip".
     */}}
{{- define "container_ip" }}
    {{- $ip := "" }}
    #     networks:
    {{- range sortObjectsByKeysAsc $.container.Networks "Name" }}
        {{- /*
             * TODO: Only ignore the "ingress" network for Swarm tasks (in case
             * the user is not using Swarm mode and names a network "ingress").
             */}}
        {{- if eq .Name "ingress" }}
    #         {{ .Name }} (ignored)
            {{- continue }}
        {{- end }}
        {{- if and (not (index $.globals.networks .Name)) (not $.globals.networks.host) }}
    #         {{ .Name }} (unreachable)
            {{- continue }}
        {{- end }}
        {{- /*
             * Do not emit multiple `server` directives for this container if it
             * is reachable over multiple networks.  This avoids accidentally
             * inflating the effective round-robin weight of a server due to the
             * redundant upstream addresses that nginx sees as belonging to
             * distinct servers.
             */}}
        {{- if $ip }}
    #         {{ .Name }} (ignored; reachable but redundant)
            {{- continue }}
        {{- end }}
    #         {{ .Name }} (reachable)
        {{- if and . .IP }}
            {{- $ip = .IP }}
        {{- else }}
    #             /!\ No IP for this network!
        {{- end }}
    {{- else }}
    #         (none)
    {{- end }}
    #     IP address: {{ if $ip }}{{ $ip }}{{ else }}(none usable){{ end }}
    {{- $_ := set $ "ip" $ip }}
{{- end }}

{{- /*
     * Template used as a function to get the port of the server in the given
     * container.  This template only outputs debug comments; the port is
     * "returned" by storing the value in the provided dot dict.
     *
     * The provided dot dict is expected to have the following entries:
     *   - "container": The container's RuntimeContainer struct.
     *
     * The return value will be added to the dot dict with key "port".
     */}}
{{- define "container_port" }}
    {{- /* If only 1 port exposed, use that as a default, else 80. */}}
    #     exposed ports:{{ range sortObjectsByKeysAsc $.container.Addresses "Port" }} {{ .Port }}/{{ .Proto }}{{ else }} (none){{ end }}
    {{- $default_port := when (eq (len $.container.Addresses) 1) (first $.container.Addresses).Port "80" }}
    #     default port: {{ $default_port }}
    {{- $port := or $.container.Env.VIRTUAL_PORT $default_port }}
    #     using port: {{ $port }}
    {{- $addr_obj := where $.container.Addresses "Port" $port | first }}
    {{- if and $addr_obj $addr_obj.HostPort }}
    #         /!\ WARNING: Virtual port published on host.  Clients
    #                      might be able to bypass nginx-proxy and
    #                      access the container's server directly.
    {{- end }}
    {{- $_ := set $ "port" $port }}
{{- end }}

{{- define "ssl_policy" }}
    {{- if eq .ssl_policy "Mozilla-Modern" }}
    ssl_protocols TLSv1.3;
        {{- /*
             * nginx currently lacks ability to choose ciphers in TLS 1.3 in
             * configuration; see https://trac.nginx.org/nginx/ticket/1529.  A
             * possible workaround can be modify /etc/ssl/openssl.cnf to change
             * it globally (see
             * https://trac.nginx.org/nginx/ticket/1529#comment:12).  Explicitly
             * set ngnix default value in order to allow single servers to
             * override the global http value.
             */}}
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;
    {{- else if eq .ssl_policy "Mozilla-Intermediate" }}
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    {{- else if eq .ssl_policy "Mozilla-Old" }}
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA256:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-TLS-1-2-2017-01" }}
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:AES128-GCM-SHA256:AES128-SHA256:AES256-GCM-SHA384:AES256-SHA256';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-TLS-1-1-2017-01" }}
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-2016-08" }}
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-2015-05" }}
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA:DES-CBC3-SHA';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-2015-03" }}
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA:DHE-DSS-AES128-SHA:DES-CBC3-SHA';
    ssl_prefer_server_ciphers on;
    {{- else if eq .ssl_policy "AWS-2015-02" }}
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:AES128-GCM-SHA256:AES128-SHA256:AES128-SHA:AES256-GCM-SHA384:AES256-SHA256:AES256-SHA:DHE-DSS-AES128-SHA';
    ssl_prefer_server_ciphers on;
    {{- end }}
{{- end }}

{{- define "location" }}
    {{- $override := printf "/etc/nginx/vhost.d/%s_%s_location_override" .Host (sha1 .Path) }}
    {{- if and (eq .Path "/") (not (exists $override)) }}
        {{- $override = printf "/etc/nginx/vhost.d/%s_location_override" .Host }}
    {{- end }}
    {{- if exists $override }}
    include {{ $override }};
    {{- else }}
        {{- $keepalive := first (keys (groupByLabel .Containers "com.github.nginx-proxy.nginx-proxy.keepalive")) }}
    location {{ .Path }} {
        {{- if eq .NetworkTag "internal" }}
        # Only allow traffic from internal clients
        include /etc/nginx/network_internal.conf;
        {{- end }}

        {{- if eq .Proto "uwsgi" }}
        include uwsgi_params;
        uwsgi_pass {{ trim .Proto }}://{{ trim .Upstream }};
        {{- else if eq .Proto "fastcgi" }}
        root {{ trim .VhostRoot }};
        include fastcgi_params;
        fastcgi_pass {{ trim .Upstream }};
            {{- if $keepalive }}
        fastcgi_keep_conn on;
            {{- end }}
        {{- else if eq .Proto "grpc" }}
        grpc_pass {{ trim .Proto }}://{{ trim .Upstream }};
        {{- else }}
        proxy_pass {{ trim .Proto }}://{{ trim .Upstream }}{{ trim .Dest }};
        set $upstream_keepalive {{ if $keepalive }}true{{ else }}false{{ end }};
        {{- end }}

        {{- if (exists (printf "/etc/nginx/htpasswd/%s" .Host)) }}
        auth_basic "Restricted {{ .Host }}";
        auth_basic_user_file {{ (printf "/etc/nginx/htpasswd/%s" .Host) }};
        {{- end }}

        {{- if (exists (printf "/etc/nginx/vhost.d/%s_%s_location" .Host (sha1 .Path) )) }}
        include {{ printf "/etc/nginx/vhost.d/%s_%s_location" .Host (sha1 .Path) }};
        {{- else if (exists (printf "/etc/nginx/vhost.d/%s_location" .Host)) }}
        include {{ printf "/etc/nginx/vhost.d/%s_location" .Host}};
        {{- else if (exists "/etc/nginx/vhost.d/default_location") }}
        include /etc/nginx/vhost.d/default_location;
        {{- end }}
    }
    {{- end }}
{{- end }}

{{- define "upstream" }}
upstream {{ .Upstream }} {
    {{- $server_found := false }}
    {{- $loadbalance := first (keys (groupByLabel .Containers "com.github.nginx-proxy.nginx-proxy.loadbalance")) }}
    {{- if $loadbalance }}
    # From the container's loadbalance label:
    {{ $loadbalance }}
    {{- end }}
    {{- range $container := .Containers }}
    # Container: {{ $container.Name }}
        {{- $args := dict "globals" $.globals "container" $container }}
        {{- template "container_ip" $args }}
        {{- $ip := $args.ip }}
        {{- $args := dict "container" $container }}
        {{- template "container_port" $args }}
        {{- $port := $args.port }}
        {{- if $ip }}
            {{- $server_found = true }}
    server {{ $ip }}:{{ $port }};
        {{- end }}
    {{- end }}
    {{- /* nginx-proxy/nginx-proxy#1105 */}}
    {{- if not $server_found }}
    # Fallback entry
    server 127.0.0.1 down;
    {{- end }}
    {{- $keepalive := first (keys (groupByLabel .Containers "com.github.nginx-proxy.nginx-proxy.keepalive")) }}
    {{- if $keepalive }}
    keepalive {{ $keepalive }};
    {{- end }}
}
{{- end }}

# If we receive X-Forwarded-Proto, pass it through; otherwise, pass along the
# scheme used to connect to this server
map $http_x_forwarded_proto $proxy_x_forwarded_proto {
    default {{ if $globals.trust_downstream_proxy }}$http_x_forwarded_proto{{ else }}$scheme{{ end }};
    '' $scheme;
}

map $http_x_forwarded_host $proxy_x_forwarded_host {
    default {{ if $globals.trust_downstream_proxy }}$http_x_forwarded_host{{ else }}$http_host{{ end }};
    '' $http_host;
}

# If we receive X-Forwarded-Port, pass it through; otherwise, pass along the
# server port the client connected to
map $http_x_forwarded_port $proxy_x_forwarded_port {
    default {{ if $globals.trust_downstream_proxy }}$http_x_forwarded_port{{ else }}$server_port{{ end }};
    '' $server_port;
}

# If the request from the downstream client has an "Upgrade:" header (set to any
# non-empty value), pass "Connection: upgrade" to the upstream (backend) server.
# Otherwise, the value for the "Connection" header depends on whether the user
# has enabled keepalive to the upstream server.
map $http_upgrade $proxy_connection {
    default upgrade;
    '' $proxy_connection_noupgrade;
}
map $upstream_keepalive $proxy_connection_noupgrade {
    # Preserve nginx's default behavior (send "Connection: close").
    default close;
    # Use an empty string to cancel nginx's default behavior.
    true '';
}
# Abuse the map directive (see <https://stackoverflow.com/q/14433309>) to ensure
# that $upstream_keepalive is always defined.  This is necessary because:
#   - The $proxy_connection variable is indirectly derived from
#     $upstream_keepalive, so $upstream_keepalive must be defined whenever
#     $proxy_connection is resolved.
#   - The $proxy_connection variable is used in a proxy_set_header directive in
#     the http block, so it is always fully resolved for every request -- even
#     those where proxy_pass is not used (e.g., unknown virtual host).
map "" $upstream_keepalive {
    # The value here should not matter because it should always be overridden in
    # a location block (see the "location" template) for all requests where the
    # value actually matters.
    default false;
}

# Apply fix for very long server names
server_names_hash_bucket_size 128;

# Default dhparam
{{- if (exists "/etc/nginx/dhparam/dhparam.pem") }}
ssl_dhparam /etc/nginx/dhparam/dhparam.pem;
{{- end }}

# Set appropriate X-Forwarded-Ssl header based on $proxy_x_forwarded_proto
map $proxy_x_forwarded_proto $proxy_x_forwarded_ssl {
    default off;
    https on;
}

gzip_types text/plain text/css application/javascript application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript;

log_format vhost '{{ or $globals.Env.LOG_FORMAT "$host $remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\" \"$upstream_addr\"" }}';

access_log off;

{{- template "ssl_policy" (dict "ssl_policy" $globals.ssl_policy) }}
error_log /dev/stderr;

{{- if $globals.Env.RESOLVERS }}
resolver {{ $globals.Env.RESOLVERS }};
{{- end }}

{{- if (exists "/etc/nginx/proxy.conf") }}
include /etc/nginx/proxy.conf;
{{- else }}
# HTTP 1.1 support
proxy_http_version 1.1;
proxy_buffering off;
proxy_set_header Host $http_host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $proxy_connection;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host $proxy_x_forwarded_host;
proxy_set_header X-Forwarded-Proto $proxy_x_forwarded_proto;
proxy_set_header X-Forwarded-Ssl $proxy_x_forwarded_ssl;
proxy_set_header X-Forwarded-Port $proxy_x_forwarded_port;
proxy_set_header X-Original-URI $request_uri;

# Mitigate httpoxy attack (see README for details)
proxy_set_header Proxy "";
{{- end }}

{{- /*
     * Precompute some information about each vhost.  This is done early because
     * the creation of fallback servers depends on DEFAULT_HOST, HTTPS_METHOD,
     * and whether there are any missing certs.
     */}}
{{- range $vhost, $containers := groupByMulti $globals.containers "Env.VIRTUAL_HOST" "," }}
    {{- $vhost := trim $vhost }}
    {{- if not $vhost }}
        {{- /* Ignore containers with VIRTUAL_HOST set to the empty string. */}}
        {{- continue }}
    {{- end }}
    {{- $certName := first (groupByKeys $containers "Env.CERT_NAME") }}
    {{- $vhostCert := closest (dir "/etc/nginx/certs") (printf "%s.crt" $vhost) }}
    {{- $vhostCert = trimSuffix ".crt" $vhostCert }}
    {{- $vhostCert = trimSuffix ".key" $vhostCert }}
    {{- $cert := or $certName $vhostCert }}
    {{- $cert_ok := and (ne $cert "") (exists (printf "/etc/nginx/certs/%s.crt" $cert)) (exists (printf "/etc/nginx/certs/%s.key" $cert)) }}
    {{- $default := eq $globals.Env.DEFAULT_HOST $vhost }}
    {{- $https_method := or (first (groupByKeys $containers "Env.HTTPS_METHOD")) $globals.Env.HTTPS_METHOD "redirect" }}
    {{- $_ := set $globals.vhosts $vhost (dict "cert" $cert "cert_ok" $cert_ok "containers" $containers "default" $default "https_method" $https_method) }}
{{- end }}

{{- /*
     * If needed, create a catch-all fallback server to send an error code to
     * clients that request something from an unknown vhost.
     *
     * This server must appear first in the generated config because nginx uses
     * the first `server` directive to handle requests that don't match any of
     * the other `server` directives.  An alternative approach would be to add
     * the `default_server` option to the `listen` directives inside this
     * `server`, but some users inject a custom `server` directive that uses
     * `default_server`.  Using `default_server` here would cause nginx to fail
     * to start for those users.  See
     * <https://github.com/nginx-proxy/nginx-proxy/issues/2212>.
     */}}
{{- block "fallback_server" $globals }}
    {{- $globals := . }}
    {{- $http_exists := false }}
    {{- $https_exists := false }}
    {{- $default_http_exists := false }}
    {{- $default_https_exists := false }}
    {{- range $vhost := $globals.vhosts }}
        {{- $http := or (ne $vhost.https_method "nohttp") (not $vhost.cert_ok) }}
        {{- $https := ne $vhost.https_method "nohttps" }}
        {{- $http_exists = or $http_exists $http }}
        {{- $https_exists = or $https_exists $https }}
        {{- $default_http_exists = or $default_http_exists (and $http $vhost.default) }}
        {{- $default_https_exists = or $default_https_exists (and $https $vhost.default) }}
    {{- end }}
    {{- $fallback_http := and $http_exists (not $default_http_exists) }}
    {{- $fallback_https := and $https_exists (not $default_https_exists) }}
    {{- /*
         * If there are no vhosts at all, create fallbacks for both plain http
         * and https so that clients get something more useful than a connection
         * refused error.
         */}}
    {{- if and (not $http_exists) (not $https_exists) }}
        {{- $fallback_http = true }}
        {{- $fallback_https = true }}
    {{- end }}
    {{- if or $fallback_http $fallback_https }}
server {
    server_name _; # This is just an invalid value which will never trigger on a real hostname.
    server_tokens off;
    location /static {
    alias /usr/share/nginx/html/static;
}
        {{- if $fallback_http }}
    listen {{ $globals.external_http_port }}; {{- /* Do not add `default_server` (see comment above). */}}
                {{- if $globals.enable_ipv6 }}
    listen [::]:{{ $globals.external_http_port }}; {{- /* Do not add `default_server` (see comment above). */}}
                {{- end }}
        {{- end }}
        {{- if $fallback_https }}
    listen {{ $globals.external_https_port }} ssl http2; {{- /* Do not add `default_server` (see comment above). */}}
            {{- if $globals.enable_ipv6 }}
    listen [::]:{{ $globals.external_https_port }} ssl http2; {{- /* Do not add `default_server` (see comment above). */}}
            {{- end }}
        {{- end }}
    {{ $globals.access_log }}
        {{- if $globals.default_cert_ok }}
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_certificate /etc/nginx/certs/default.crt;
    ssl_certificate_key /etc/nginx/certs/default.key;
        {{- else }}
    # No default.crt certificate found for this vhost, so force nginx to emit a
    # TLS error if the client connects via https.
    {{- /* See the comment in the main `server` directive for rationale. */}}
    ssl_ciphers aNULL;
    set $empty "";
    ssl_certificate data:$empty;
    ssl_certificate_key data:$empty;
    if ($https) {
        return 444;
    }
        {{- end }}
    return 503;
}
    {{- end }}
{{- end }}

{{- range $host, $vhost := $globals.vhosts }}
    {{- $cert := $vhost.cert }}
    {{- $cert_ok := $vhost.cert_ok }}
    {{- $containers := $vhost.containers }}
    {{- $default_server := when $vhost.default "default_server" "" }}
    {{- $https_method := $vhost.https_method }}

    {{- $is_regexp := hasPrefix "~" $host }}
    {{- $upstream_name := when (or $is_regexp $globals.sha1_upstream_name) (sha1 $host) $host }}

    {{- $paths := groupBy $containers "Env.VIRTUAL_PATH" }}
    {{- $nPaths := len $paths }}
    {{- if eq $nPaths 0 }}
        {{- $paths = dict "/" $containers }}
    {{- end }}

    {{- range $path, $containers := $paths }}
        {{- $upstream := $upstream_name }}
        {{- if gt $nPaths 0 }}
            {{- $sum := sha1 $path }}
            {{- $upstream = printf "%s-%s" $upstream $sum }}
        {{- end }}
# {{ $host }}{{ $path }}
{{ template "upstream" (dict "globals" $globals "Upstream" $upstream "Containers" $containers) }}
    {{- end }}

    {{- /*
         * Get the SERVER_TOKENS defined by containers w/ the same vhost,
         * falling back to "".
         */}}
    {{- $server_tokens := trim (or (first (groupByKeys $containers "Env.SERVER_TOKENS")) "") }}

    {{- /*
         * Get the SSL_POLICY defined by containers w/ the same vhost, falling
         * back to empty string (use default).
         */}}
    {{- $ssl_policy := or (first (groupByKeys $containers "Env.SSL_POLICY")) "" }}

    {{- /*
         * Get the HSTS defined by containers w/ the same vhost, falling back to
         * "max-age=31536000".
         */}}
    {{- $hsts := or (first (groupByKeys $containers "Env.HSTS")) (or $globals.Env.HSTS "max-age=31536000") }}

    {{- /* Get the VIRTUAL_ROOT By containers w/ use fastcgi root */}}
    {{- $vhost_root := or (first (groupByKeys $containers "Env.VIRTUAL_ROOT")) "/var/www/public" }}

    {{- if and $cert_ok (eq $https_method "redirect") }}
server {
    server_name {{ $host }};
        {{- if $server_tokens }}
    server_tokens {{ $server_tokens }};
        {{- end }}
    listen {{ $globals.external_http_port }} {{ $default_server }};
        {{- if $globals.enable_ipv6 }}
    listen [::]:{{ $globals.external_http_port }} {{ $default_server }};
        {{- end }}
    {{ $globals.access_log }}

    # Do not HTTPS redirect Let's Encrypt ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        auth_request off;
        allow all;
        root /usr/share/nginx/html;
        try_files $uri =404;
        break;
    }

    location / {
        {{- if eq $globals.external_https_port "443" }}
        return 301 https://$host$request_uri;
        {{- else }}
        return 301 https://$host:{{ $globals.external_https_port }}$request_uri;
        {{- end }}
    }
}
    {{- end }}

server {
    server_name {{ $host }};
    {{- if $server_tokens }}
    server_tokens {{ $server_tokens }};
    {{- end }}
    {{ $globals.access_log }}
    {{- if or (eq $https_method "nohttps") (not $cert_ok) (eq $https_method "noredirect") }}
    listen {{ $globals.external_http_port }} {{ $default_server }};
        {{- if $globals.enable_ipv6 }}
    listen [::]:{{ $globals.external_http_port }} {{ $default_server }};
        {{- end }}
    {{- end }}
    {{- if ne $https_method "nohttps" }}
    listen {{ $globals.external_https_port }} ssl http2 {{ $default_server }};
        {{- if $globals.enable_ipv6 }}
    listen [::]:{{ $globals.external_https_port }} ssl http2 {{ $default_server }};
        {{- end }}

        {{- if $cert_ok }}
            {{- template "ssl_policy" (dict "ssl_policy" $ssl_policy) }}

    ssl_session_timeout 5m;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    ssl_certificate /etc/nginx/certs/{{ (printf "%s.crt" $cert) }};
    ssl_certificate_key /etc/nginx/certs/{{ (printf "%s.key" $cert) }};

            {{- if (exists (printf "/etc/nginx/certs/%s.dhparam.pem" $cert)) }}
    ssl_dhparam {{ printf "/etc/nginx/certs/%s.dhparam.pem" $cert }};
            {{- end }}

            {{- if (exists (printf "/etc/nginx/certs/%s.chain.pem" $cert)) }}
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate {{ printf "/etc/nginx/certs/%s.chain.pem" $cert }};
            {{- end }}

            {{- if (not (or (eq $https_method "noredirect") (eq $hsts "off"))) }}
    set $sts_header "";
    if ($https) {
        set $sts_header "{{ trim $hsts }}";
    }
    add_header Strict-Transport-Security $sts_header always;
            {{- end }}
        {{- else if $globals.default_cert_ok }}
    # No certificate found for this vhost, so use the default certificate and
    # return an error code if the user connects via https.
    ssl_certificate /etc/nginx/certs/default.crt;
    ssl_certificate_key /etc/nginx/certs/default.key;
    if ($https) {
        return 500;
    }
        {{- else }}
    # No certificate found for this vhost, so force nginx to emit a TLS error if
    # the client connects via https.
            {{- /*
                 * The alternative is to not provide an https server for this
                 * vhost, which would either cause the user to see the wrong
                 * vhost (if there is another vhost with a certificate) or a
                 * connection refused error (if there is no other vhost with a
                 * certificate).  A TLS error is easier to troubleshoot, and is
                 * safer than serving the wrong vhost.  Also see
                 * <https://serverfault.com/a/1044022>.
                 */}}
    ssl_ciphers aNULL;
    set $empty "";
    ssl_certificate data:$empty;
    ssl_certificate_key data:$empty;
    if ($https) {
        return 444;
    }
        {{- end }}
    {{- end }}

    {{- if (exists (printf "/etc/nginx/vhost.d/%s" $host)) }}
    include {{ printf "/etc/nginx/vhost.d/%s" $host }};
    {{- else if (exists "/etc/nginx/vhost.d/default") }}
    include /etc/nginx/vhost.d/default;
    {{- end }}

    {{- range $path, $containers := $paths }}
        {{- /*
             * Get the VIRTUAL_PROTO defined by containers w/ the same
             * vhost-vpath, falling back to "http".
             */}}
        {{- $proto := trim (or (first (groupByKeys $containers "Env.VIRTUAL_PROTO")) "http") }}

        {{- /*
             * Get the NETWORK_ACCESS defined by containers w/ the same vhost,
             * falling back to "external".
             */}}
        {{- $network_tag := or (first (groupByKeys $containers "Env.NETWORK_ACCESS")) "external" }}
        {{- $upstream := $upstream_name }}
        {{- $dest := "" }}
        {{- if gt $nPaths 0 }}
            {{- $sum := sha1 $path }}
            {{- $upstream = printf "%s-%s" $upstream $sum }}
            {{- $dest = (or (first (groupByKeys $containers "Env.VIRTUAL_DEST")) "") }}
        {{- end }}
        {{- template "location" (dict "Path" $path "Proto" $proto "Upstream" $upstream "Host" $host "VhostRoot" $vhost_root "Dest" $dest "NetworkTag" $network_tag "Containers" $containers) }}
    {{- end }}
    {{- if and (not (contains $paths "/")) (ne $globals.default_root_response "none")}}
    location / {
        return {{ $globals.default_root_response }};
    }
    {{- end }}
}
{{- end }}