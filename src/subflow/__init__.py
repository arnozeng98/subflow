"""
subflow package.

This package hosts the VPS-side private API that sits beside the upstream
Tangfffyx/sing-box installation. The package is intentionally split into small,
single-purpose modules because this project has two competing constraints:

1. It must be easy to install with a single command on a VPS.
2. It must remain maintainable while supporting multiple client subscription
   formats and upstream data sources.

Keeping the code modular is the only way to satisfy both constraints without
letting the private API collapse back into a single monolithic script.
"""
