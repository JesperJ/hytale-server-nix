# hytale-server-nix

A Nix flake and NixOS module for running a [Hytale](https://hytale.com) dedicated server.

## What it does

- Provides a NixOS module (`services.hytale-server`) that runs the vendor `start.sh` as a hardened systemd service under a dedicated system user, with the firewall opened for UDP 5520.
- Ships a `hytale-setup` command that downloads Hytale's official downloader, authenticates against your Hytale account (OAuth2 device-code flow), fetches the latest server archive, and extracts it into the service's `dataDir`.

## What it does NOT do

- **Does not bundle `HytaleServer.jar` or `Assets.zip`.** Those are proprietary, auth-gated files that must be fetched with your Hytale account credentials.
- Does not manage backups of your worlds (the vendor `start.sh` runs periodic in-game backups into `Server/backups/`, but for offsite backup you should point `borgbackup`/`restic` at `dataDir`).

## Prerequisites

- A Hytale account with dedicated-server download access.
- ~5 GB free disk in `dataDir` (`HytaleServer.jar` ~117 MB, `Assets.zip` ~3.2 GB, plus AOT cache and world data).
- Outbound HTTPS (to auth + download) and inbound UDP on the chosen port (default 5520). If you're behind NAT, forward that UDP port to the server host.

## Usage

### 1. Add the flake as an input

```nix
{
  inputs.hytale-server = {
    url = "github:JesperJ/hytale-server-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

### 2. Import the module and enable the service

```nix
{
  imports = [ inputs.hytale-server.nixosModules.default ];

  services.hytale-server = {
    enable = true;
    heapSize = "4G";
    # dataDir = "/var/lib/hytale-server";   # default
    # port = 5520;                           # default (UDP only)
    # openFirewall = true;                   # default
    # extraJvmOpts = [ "-XX:+UseG1GC" ];     # optional
  };
}
```

`nixos-rebuild switch` will create the `hytale` user, the empty `dataDir`, and install `hytale-setup` into `$PATH`. The service will fail to start until you install the server files.

### 3. Install the server files

Run the installer once as the `hytale` user, in `dataDir`:

```bash
sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup'
```

On first run this prints an OAuth2 device-code URL and code. Open the URL in a browser (any browser, anywhere), sign in to your Hytale account, and enter the code. The tool caches credentials in `dataDir/.hytale-downloader-credentials.json` and proceeds to download + extract ~3.5 GB.

### 4. Start the service

```bash
sudo systemctl start hytale-server
sudo journalctl -fu hytale-server
```

### 5. Authenticate the server (one-time, semi-automated)

Fresh installs also need a one-time server-side auth against Hypixel's session infrastructure — separate from the downloader auth in step 3. Without it, you'll see this in the journal on every boot:

```
[WARN] [HytaleServer] No server tokens configured. Use /auth login to authenticate.
```

`hytale-setup auth` wraps the ceremony. It refuses to run while the systemd service is active, so stop the service first:

```bash
sudo systemctl stop hytale-server
sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup auth'
```

The script prints instructions, then launches the server in interactive mode. When you see `Hytale Server Booted!`, type at the prompt (this is an in-server console command, not a shell command):

```
/auth login device
```

The server prints a URL and a short code. Open the URL in any browser, sign in with your Hytale account, enter the code, and wait for:

```
[ServerAuthManager] Authentication successful! Mode: OAUTH_STORE
```

Then type `/stop`. Control returns to `hytale-setup auth`, which prints the next step:

```bash
sudo systemctl start hytale-server
```

The token is cached as `Server/auth.enc` (encrypted) and picked up automatically on subsequent starts. The `No server tokens configured` warning should be gone; look for `Session restored from stored credentials` instead.

Other `/auth` subcommands available at the interactive prompt: `status`, `login browser`, `select <profile>`, `logout`, `cancel`, `persistence <type>`. Append `--help` to any for details.

## Updating the game

For a clean update, stop the service and re-run the installer with the `update` subcommand — credentials are cached, so it's non-interactive:

```bash
sudo systemctl stop hytale-server
sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup update'
sudo systemctl start hytale-server
```

The vendor `start.sh` also handles staged updates internally while the service is running (exit code 8 triggers a restart), so most updates land without manual intervention.

## Updating the OAuth2 credentials

If auth breaks (e.g. tokens revoked):

```bash
sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup --force-auth'
```

## Selecting a different patchline

```bash
sudo -u hytale -H bash -c 'cd /var/lib/hytale-server && hytale-setup --patchline pre-release'
```

Available patchlines are listed by the underlying downloader — see [QUICKSTART.md in the Hytale downloader archive](https://downloader.hytale.com/hytale-downloader.zip) for the current list.

## Module options

| Option | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `enable` | bool | `false` | Enable the server. |
| `dataDir` | path | `/var/lib/hytale-server` | Working directory. |
| `user` / `group` | str | `hytale` | System user/group. |
| `port` | port | `5520` | UDP port. |
| `openFirewall` | bool | `true` | Open `port` in the firewall (UDP). |
| `heapSize` | str | `"4G"` | Both `-Xms` and `-Xmx`; written to `jvm.options`. |
| `extraJvmOpts` | list str | `[]` | Extra lines appended to `jvm.options`. |

The module writes `<dataDir>/jvm.options` on every service start, so option changes take effect on the next `systemctl restart hytale-server` (no manual edits needed).

## Files created in `dataDir`

- `start.sh`, `start.bat`, `Server/`, `Assets.zip` — from the vendor archive
- `Server/backups/` — periodic in-game backups (managed by `start.sh`, default 30-min frequency)
- `Server/config/`, `Server/mods/`, `Server/worlds/` — server state
- `jvm.options` — managed by this module; do not edit
- `.hytale-downloader`, `.hytale-downloader-credentials.json` — created by `hytale-setup`; keep credentials private

## Mods

Drop `.zip` / `.jar` mod files into `<dataDir>/Server/mods/`. Connecting players receive them automatically.

## Security notes

- Only UDP `port` needs to be reachable; TCP is unused.
- `.hytale-downloader-credentials.json` grants access to your Hytale account for downloads — treat it like an API key.
- If exposing the server to the internet, avoid running with `--allow-op` (any player can `/op self`). This module does not pass `--allow-op` unless you add it via `extraJvmOpts` (which you shouldn't — it's a server flag, not a JVM flag).

## License

MIT for the flake, module, and setup script. The Hytale server binaries and assets are proprietary Hypixel Studios software governed by the [Hytale EULA](https://hytale.com/eula).
