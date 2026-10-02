# Country availability

Owner decision: all available supported countries except Russia (RU) and Belarus (BY).

The OpenAI package expresses KROK's restriction as the complete ISO 3166-1 alpha-2 allowlist, excluding RU and BY (247 codes). The directory's own supported regions still constrain actual availability. Including a code does not establish that the platform operates there or override regional/sanctions restrictions. Verify the portal accepts the allowlist before submission; do not replace it with `[]`, which removes KROK's restriction.

This interpretation keeps every country the host supports eligible while excluding the two countries the owner specified. It also avoids guessing an OpenAI-supported list: its Help Center page returned HTTP 403 during research. ISO codes are checked against pycountry 24.6.1 and the actual ZIP.

[Anthropic's current supported-region policy](https://www.anthropic.com/supported-countries) was fetched successfully on 2 October 2026 (Actions run 37005114532). It separates API and Claude.ai availability and excludes certain regions of Ukraine. Claude's own restrictions continue to apply. Choose supported country controls in its portal where offered; if no publisher geographic restriction exists, resolve enforcement with the platform before publishing. This metadata does not add a geographic block to the KROK backend or App Store availability.
