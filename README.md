# qualtive-cli

The `qualtive` command-line interface for [Qualtive](https://qualtive.io). It talks to the admin API
(`https://admin-api.qualtive.io`) over REST/JSON.

```
qualtive auth login [--container <id>] [--with-token] [--no-browser]
qualtive auth logout                 # delete local credentials (no server-side sessions)
qualtive auth status [--json]        # user, container, role, auth type, expiry
qualtive auth token                  # print a valid access token (refreshes if needed)

qualtive containers list [--json]    # marks the current container with *
qualtive containers use <id>         # switch container without logging in again

qualtive categories list [--json]

qualtive update [--check]            # Homebrew: prints `brew upgrade qualtive`; self-update not yet implemented
qualtive version [--json]
```

## Authentication

- **Browser login** (default): OAuth 2.0 authorization code + PKCE (S256). The CLI listens on
  `http://127.0.0.1:<random port>/callback`, opens `/oauth/authorize` in the browser, and exchanges the code at
  `POST /oauth/token` for the regular admin token pair (30 min access token, 40-day refresh token). Access tokens
  are refreshed automatically when they have less than 60 seconds left, or after a `401 InvalidAccessToken`.
  Use `--no-browser` to print the URL instead.
- **API keys**: `echo "$KEY" | qualtive auth login --with-token [--container <id>]` stores a `u-…` or `c-…` key,
  or set `QUALTIVE_API_KEY`, which takes precedence over stored credentials.
- **Logout** only deletes the local credentials. There are no server-side sessions, so the refresh token stays
  valid until it expires, the same as logging out of the web admin.

### Where credentials are stored

| Platform | Store |
|---|---|
| macOS, Developer ID signed release | Keychain, generic password, service `io.qualtive.cli`, account = profile |
| macOS dev builds, Linux | `~/.config/qualtive/credentials.json` (or `$XDG_CONFIG_HOME/qualtive`), directory 0700, file 0600, written atomically. The CLI refuses to read it if other users can. |

Set `QUALTIVE_CREDENTIAL_STORE=file` or `keychain` to override. Non-secret settings (default container,
API URL) live in `config.json` next to it.

### Environment variables

| Variable | Meaning |
|---|---|
| `QUALTIVE_API_KEY` | API key to use instead of stored credentials |
| `QUALTIVE_CONTAINER` | Container ID (overridden by `--container`) |
| `QUALTIVE_API_URL` | Admin API base URL (for local development) |
| `QUALTIVE_CONFIG_DIR` | Directory for `config.json` and `credentials.json` |
| `QUALTIVE_CREDENTIAL_STORE` | `file` or `keychain` |

### Exit codes

`0` success, `1` error, `2` usage (including no container selected), `3` not logged in or invalid credentials,
`4` forbidden (`UnauthorizedContainer`, `InsufficientPermissions`), `5` not found, `6` network error.

## Development

Requires Swift 6.x (CI uses 6.4.1). Networking uses SwiftNIO and AsyncHTTPClient only (no `URLSession`).

```sh
swift build
swift test
swift run qualtive --help

# Fully static Linux binary (musl)
swift sdk install <static-linux-sdk-url> --checksum <checksum>
swift build -c release --swift-sdk x86_64-swift-linux-musl -Xlinker -s
```

Point the CLI at a local backend with `--api-url http://127.0.0.1:8080` or `QUALTIVE_API_URL`.

## Releases

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Static musl Linux binaries for x86_64 and aarch64.
2. A universal macOS binary, Developer ID signed (identifier `io.qualtive.cli`) and notarized.
3. A GitHub Release with `SHA256SUMS`.
4. A formula update in `nightshift-habits/homebrew-tap`.

Running the workflow manually builds artifacts only and publishes nothing. Signing uses the ccode AB Apple
Developer account for now; the required secrets are listed at the top of the workflow.
