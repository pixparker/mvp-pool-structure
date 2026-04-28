# Rendered by `mvpool mvp:add` for API+web MVPs. DO NOT hand-edit —
# edits are overwritten on next deploy. Lives at /srv/infra/sites/<slug>.caddy.

{{DOMAIN}} {
	encode zstd gzip
	log {
		output stdout
		format console
	}

	@api path /api/* /health
	handle @api {
		reverse_proxy {{API_HOST}}:{{API_PORT}}
	}

	handle {
		reverse_proxy {{WEB_HOST}}:{{WEB_PORT}}
	}
}
