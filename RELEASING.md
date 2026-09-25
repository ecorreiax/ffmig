# Releasing FFMig

Pushing a version tag publishes a release. `.github/workflows/release.yml`
then does everything else:

1. Checks that the tag matches `version` in `build.zig.zon`, and that
   `CHANGELOG.md` has a section for it.
2. Builds the binaries on each platform and runs each one against a
   PostgreSQL that accepts only TLS (`.github/workflows/build.yml` and
   `scripts/smoke.sh`, which CI also runs on every pull request).
3. Creates the GitHub release with the binaries, `SHA256SUMS`, and the
   `CHANGELOG.md` section as its notes.
4. Pushes the image `ghcr.io/ecorreiax/ffmig:<version>` and `:latest`,
   for `linux/amd64` and `linux/arm64`.
5. Writes the Homebrew formula and the Scoop manifest from `packaging/`
   (`scripts/packaging.sh`) and pushes them to the tap and the bucket.

| Asset | Used by |
|-------|---------|
| `ffmig-linux-amd64`, `ffmig-linux-arm64` | the README's `curl` install, and the Docker image |
| `ffmig-macos-arm64.tar.gz`, `ffmig-macos-amd64.tar.gz` | the Homebrew formula |
| `ffmig-windows-amd64.zip` (`ffmig.exe` and the DLLs it loads) | the Scoop manifest |
| `SHA256SUMS` | checking any of them, and Scoop's `autoupdate` |

The asset names have no version, so that `releases/latest/download/<name>`
always gives the newest.

## Cutting a release

1. Set `version` in `build.zig.zon` (the nix flake and `ffmig --version`
   read it from there).
2. Move what is new in `CHANGELOG.md` under a `## <version>` heading.
3. Commit, then tag and push:

   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```

4. Watch the Release workflow in the Actions tab. When it is green, check
   that `brew install ffmig`, the `curl` command, `scoop install ffmig`
   and `docker run ghcr.io/ecorreiax/ffmig --version` all work as
   `README.md` says.

If a build or a smoke test fails, nothing is published: fix the cause,
delete the tag (`git push --delete origin v0.1.0` and `git tag -d
v0.1.0`), and tag again. If only the image or the tap and bucket step
fails, the release itself is out: fix the cause and use *Re-run failed
jobs*.

## One-time setup

Done once, by the repository owner, before the first release:

1. **Homebrew tap.** Create the public repository `ecorreiax/homebrew-tap`.
   It may stay empty: the first release pushes `Formula/ffmig.rb` to its
   `main`. `brew tap ecorreiax/tap` finds it by that name.
2. **Scoop bucket.** Create the public repository `ecorreiax/scoop-bucket`,
   which may stay empty too (the release pushes `bucket/ffmig.json`).
3. **Token.** Create a fine-grained personal access token with *Contents:
   Read and write* on those two repositories only, and add it to this
   repository (`ecorreiax/ffmig`, where the release runs, not the tap or
   the bucket) as the Actions secret `PACKAGES_TOKEN`. Without it, the
   release still publishes the binaries and the image, and warns that the
   tap and the bucket were not updated.
4. **Image visibility.** After the first release, open the `ffmig`
   package under the account's Packages, and in its settings make it
   public, so that `docker run` works without logging in.
5. **Branch protection.** Require the CI checks on `main` (Settings,
   Branches), so that nothing merges without passing tests.

## Distribution notes

libpq, PostgreSQL's client library, is linked dynamically, and each
binary uses the one where it runs: Homebrew's `libpq` (a dependency of
the formula), the distribution's `libpq5` on Linux (the README says to
install it), the DLLs in the zip on Windows, and Debian's `libpq5` in the
image. Every one of these libpq builds supports TLS. Release builds pass
the library to link with `-Dlibpq=<file>`, since the one pkg-config finds
in the nix shell is a `/nix/store` path that users do not have.

Linking libpq statically would make each binary self-contained, at the
cost of building libpq and OpenSSL from source in `build.zig`.
