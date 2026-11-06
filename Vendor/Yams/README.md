# Vendored Yams

[Yams](https://github.com/jpsim/Yams) 6.2.2, copied in so that building Orbit never needs to reach GitHub.

- Source: https://codeload.github.com/jpsim/Yams/tar.gz/refs/tags/6.2.2
- sha256 of that tarball: c18b63003173ff886eb781e0cbb2cba612fb5c68485b0cd4e66ad06b686091e8
- Only `Sources/` is kept (CMake files removed); unmodified otherwise.
- License: MIT (see `LICENSE`). `Sources/CYaml` is libyaml, also MIT licensed (see `LICENSE-libyaml`, from github.com/yaml/libyaml).

Orbit uses it only to read the `proxies:` list of Clash YAML subscriptions.
To upgrade, replace `Sources/` with the new release's and update this file.
