# hytale-server-nix

A Nix flake and NixOS module for running a [Hytale](https://hytale.com) dedicated server.

## What it does

- Packages a small wrapper around `HytaleServer.jar` that uses JDK 25.
- Provides a NixOS module (`services.hytale-server`) that runs the server as a systemd service under a dedicated user, with the firewall opened for UDP 5520 and reasonable hardening applied.

## What it does NOT do

- **Does not download `HytaleServer.jar` or `Assets.zip`.** Those files are auth-gated behind your Hytale account. You must download them yourself and place them in the server's data directory.
- Does not manage backups. Use `borgbackup`, `restic`, or `services.borgbackup.jobs` for the `dataDir`.

## Usage

### 1. Add the flake as an input

```nix
{
  inputs.hytale-server.url = "github:<your-user>/hytale-server-nix";
  # ...
}
```

### 2. Import the module and enable the service

```nix
{
  imports = [ inputs.hytale-server.nixosModules.default ];

  services.hytale-server = {
    enable = true;
    heapSize = "4G";
    # dataDir = "/var/lib/hytale-server";  # default
    # port = 5520;                          # default
    # openFirewall = true;                  # default
    # aotCache = true;                      # default
  };
}
```

### 3. Provide the server files

After the first `nixos-rebuild switch`, the data directory exists but is empty. Download the server files from your Hytale account and place them there:

```bash
sudo cp HytaleServer.jar Assets.zip /var/lib/hytale-server/
sudo chown hytale:hytale /var/lib/hytale-server/HytaleServer.jar /var/lib/hytale-server/Assets.zip
```

Then start the service:

```bash
sudo systemctl start hytale-server
sudo journalctl -fu hytale-server
```

### 4. First-launch authentication

Hytale requires a one-time device-code auth flow on first launch. The server will print a URL and code to the journal:

```bash
sudo journalctl -fu hytale-server
```

Open the URL, enter the code, and the server will cache an auth token in `dataDir` for subsequent launches. If auth stalls the service, run the launcher command manually once as the `hytale` user:

```bash
sudo -u hytale bash -c 'cd /var/lib/hytale-server && java -jar HytaleServer.jar --assets Assets.zip'
```

## Module options

| Option | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `enable` | bool | `false` | Enable the server. |
| `dataDir` | path | `/var/lib/hytale-server` | Working directory. Place `HytaleServer.jar` and `Assets.zip` here. |
| `user` / `group` | str | `hytale` | System user/group. |
| `port` | port | `5520` | UDP port. |
| `openFirewall` | bool | `true` | Open `port` in the firewall (UDP). |
| `heapSize` | str | `"4G"` | Both `-Xms` and `-Xmx`. |
| `aotCache` | bool | `true` | Use Java 25 AOT cache (`HytaleServer.aot`). |
| `extraJavaOpts` | list str | `[]` | Extra JVM args. |
| `extraServerArgs` | list str | `[]` | Extra args to the server jar. |

## Mods

Drop `.zip` / `.jar` mod files into `<dataDir>/mods/`. Connecting players receive them automatically.

## Security notes

- Avoid `extraServerArgs = [ "--allow-op" ]` on any server exposed beyond trusted friends — it lets any player `/op self`.
- Only UDP 5520 needs to be open; TCP is unused.

## License

MIT for the flake/module code. `HytaleServer.jar` itself is proprietary — see the [Hytale EULA](https://hytale.com/eula).
