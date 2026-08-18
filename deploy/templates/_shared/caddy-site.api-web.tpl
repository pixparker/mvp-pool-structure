# Rendered by `mvpool mvp:add` for API+web MVPs. DO NOT hand-edit —
# edits are overwritten on next deploy. Lives at /srv/infra/sites/<slug>.caddy.

# 🔒 The `http://` scheme is REQUIRED and is not cosmetic.
#
# TLS on this pool terminates at the ArvanCloud edge, which then speaks plain
# HTTP to this origin. A site address written WITHOUT a scheme makes Caddy
# enable automatic HTTPS and 308-redirect HTTP->HTTPS; the edge follows that
# back to itself and the host serves an infinite redirect loop while the
# container behind it is perfectly healthy.
#
# This cost the Faraward MVP its entire public surface from 2026-07-22 to
# 2026-07-30: four slugs deployed, healthy, and unreachable. Every other site
# on the pool had been hand-patched with `http://` after `mvp:add` rendered it
# without one; those hand-patches survive because only `mvp:add` writes these
# files (`deploy` merely reloads Caddy), which is also why the "overwritten on
# next deploy" warning above is not true today.
#
# If this pool ever terminates TLS at Caddy itself, `site_address()` in
# deploy/bin/mvpool is the ONE line to change, then re-render each site with
# `mvpool mvp:set-domain <slug> <its own domain>`.
#
# The scheme is applied PER HOST by `site_address()` rather than written here,
# because a DOMAIN may carry several comma-separated hosts and prefixing only
# the first leaves the rest looping — the same bug wearing a disguise.
{{SITE_ADDRESS}} {
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
