# `ctrld` OpenWrt 25.12+ APK Package

> [!WARNING]
> This is a personal OpenWRT package. It has only been tested on router target I use.
> Use at your own risk.
> 

OpenWrt 25.12+ package definition for [Control D's `ctrld`](https://github.com/Control-D-Inc/ctrld) multi-protocol DNS forwarding proxy (`net/ctrld`).

This package compiles `ctrld` from upstream Go source using the official OpenWrt `golang-package.mk` framework and bundles native UCI configuration (`/etc/config/ctrld`) and a `procd` init script (`/etc/init.d/ctrld`).

See the [repository README](../../README.md) for feed setup, building, and repository hosting instructions.

---

## Installation

### From the Hosted APK v3 Feed (Recommended)

After adding this feed's public key and repository URL (see the [root README](../../README.md)), install directly on your OpenWrt 25.12+ router:

```sh
apk update
apk add ctrld
```

## Configuring & Managing `ctrld`

The package ships **disabled by default** (`option enabled '0'` in `/etc/config/ctrld`), following OpenWrt best practices for network services—installing via `apk add ctrld` will not start the daemon until you configure it and set `enabled` to `'1'`.

On installation, `/etc/uci-defaults/99-ctrld` seeds `/etc/config/ctrld` from `/usr/share/ctrld/ctrld.config.default` only if `/etc/config/ctrld` does not already exist—an existing `/etc/config/ctrld` is never overwritten on install or upgrade. Likewise, when started for the first time with `cd_uid` unset and no `/etc/controld/ctrld.toml` present, `/etc/init.d/ctrld` seeds `/etc/controld/ctrld.toml` from `/usr/share/ctrld/ctrld.toml.default` without overwriting an existing file.

### Control D Mode (`--cd`)

```sh
uci set ctrld.main.cd_uid='YOUR_RESOLVER_ID'
uci set ctrld.main.enabled='1'
uci commit ctrld
/etc/init.d/ctrld enable
/etc/init.d/ctrld restart
```

### Custom TOML Config Mode (`/etc/controld/ctrld.toml`)

Edit `/etc/controld/ctrld.toml`, then run:

```sh
uci set ctrld.main.cd_uid=''
uci set ctrld.main.config_file='/etc/controld/ctrld.toml'
uci set ctrld.main.enabled='1'
uci commit ctrld
/etc/init.d/ctrld enable
/etc/init.d/ctrld restart
```

### UCI Options (`/etc/config/ctrld`)

| Option | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `0` | Enable (`1`) or disable (`0`) the service |
| `cd_uid` | `''` | Control D Resolver ID for API auto-configuration |
| `config_file` | `/etc/controld/ctrld.toml` | Path to local TOML configuration file |
| `homedir` | `/etc/controld` | Directory for `ctrld` runtime state |
| `iface` | `auto` | Interface for router/`dnsmasq` integration (`auto`, `br-lan`, or empty) |
| `verbose` | `0` | Log verbosity: `0` (default), `1` (`-v`), `2` (`-vv`) |
| `skip_self_checks` | `0` | Bypass startup self-check DNS queries (`0` or `1`) |
| `fix_dnsmasq_confdir` | `0` | Opt-in helper to set `dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'` when unset |
| `extra_args` | `''` | Additional space-separated CLI flags passed to `ctrld run` |

### Service Commands & Logs

```sh
/etc/init.d/ctrld status
/etc/init.d/ctrld restart
logread -e ctrld
/usr/sbin/ctrld --version
```

### OpenWrt 25.12 `dnsmasq` `confdir` Compatibility Note

OpenWrt 24.10+ and 25.12 default `dnsmasq` to per-instance config directories (`/tmp/dnsmasq.<cfg>.d`), whereas `ctrld` expects `/tmp/dnsmasq.d/ctrld.conf` when configuring `dnsmasq` automatically.

To avoid modifying another service's UCI configuration unexpectedly, `option fix_dnsmasq_confdir` defaults to `'0'`. To opt in (or pass `--fix-dnsmasq-confdir` to the installer scripts):

```sh
uci set ctrld.main.fix_dnsmasq_confdir='1'
uci commit ctrld
/etc/init.d/ctrld restart
```

### Security Note

`ctrld` runs as `root` because it binds privileged DNS port 53 and integrates with OpenWrt's `dnsmasq` configuration (`/tmp/dnsmasq.d`).

---

## Upgrading & Uninstalling

### Upgrade

Your `/etc/config/ctrld` and `/etc/controld/` directory are declared in `conffiles` and preserved by `apk` across upgrades and `sysupgrade`:

```sh
apk update
apk upgrade ctrld
```

### Uninstall

```sh
/etc/init.d/ctrld stop
/etc/init.d/ctrld disable
apk del ctrld
```

If you enabled `fix_dnsmasq_confdir` and want to revert `dnsmasq` to OpenWrt's default:

```sh
uci -q delete dhcp.@dnsmasq[0].confdir
uci commit dhcp
/etc/init.d/dnsmasq reload
```
