# 5 RANGER Arma 3 yolk — thin overlay over upstream.
#
# Upstream:   ghcr.io/parkervcp/games:arma3 (parkervcp/yolks, games/arma3)
# Downstream: ghcr.io/5ranger/5ranger-arma3:latest, pulled by Wings for the Arma 3 egg
# Uses:       nothing beyond the base image; the entrypoint needs only tools debian already ships
#
# Replaces only /entrypoint.sh. Everything else — base packages, locale, NSS wrapper, tini,
# the container user — is inherited, so the image keeps tracking upstream. The divergence is
# the two changes in README.md and goes away when the upstream PRs land.
FROM ghcr.io/parkervcp/games:arma3

COPY --chown=container:container ./entrypoint.sh /entrypoint.sh
