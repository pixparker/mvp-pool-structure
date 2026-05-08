# Rendered by `mvpool mvp:add` for single-container node-server MVPs.
# DO NOT hand-edit — edits are overwritten on next deploy. Lives at
# /srv/infra/sites/<slug>.caddy.

{{DOMAIN}} {
	encode zstd gzip
	log {
		output stdout
		format console
	}

	handle {
		reverse_proxy {{APP_HOST}}:{{APP_PORT}}
	}
}
