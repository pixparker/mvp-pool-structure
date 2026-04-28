# Rendered by `mvpool mvp:add` for static MVPs. DO NOT hand-edit —
# edits are overwritten on next deploy. Lives at /srv/infra/sites/<slug>.caddy.

{{DOMAIN}} {
	encode zstd gzip
	log {
		output stdout
		format console
	}

	handle {
		reverse_proxy {{WEB_HOST}}:80
	}
}
