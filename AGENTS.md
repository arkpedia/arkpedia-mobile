# Arkpedia Mobile

This private repository contains Android/iOS wrappers for the production website.
Use `https://www.arkpedia.net` only; do not point builds at Preview or retired hosts.
Do not copy the website's server, private account data, or deployment credentials.

Keep `net.arkpedia.mobile` consistent across Capacitor and native project settings.
Run `npm ci`, `npm run check`, and `npm run sync` before native builds. Use feature
branches and pull requests after the initial repository bootstrap.

Never commit signing credentials. Clearly distinguish debug APKs, unsigned IPAs,
signed device builds, and store releases. A compile-only check is not device testing.
Do not broaden navigation permissions or add native plugins without reviewing the
remote website's access to the bridge. Verify real-device OAuth before claiming
account sign-in works.
