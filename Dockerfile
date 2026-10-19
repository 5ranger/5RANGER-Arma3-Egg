# 5 RANGER Arma 3 yolk — thin overlay over upstream.
#
# Upstream:   ghcr.io/parkervcp/games:arma3 (parkervcp/yolks, games/arma3)
# Downstream: Pterodactyl egg 68 "Arma 3", servers Operations (G1) and Operations (F1)
# Uses:       nothing beyond the base image; the entrypoint needs only tools debian already ships
#
# Replaces only /entrypoint.sh. Everything else — base packages, locale, NSS wrapper, tini,
# the container user — is inherited, so the image keeps tracking upstream. The divergence is
# the two changes in README.md and goes away when the upstream PRs land.
FROM ghcr.io/parkervcp/games:arma3

COPY --chown=container:container ./entrypoint.sh /entrypoint.sh
