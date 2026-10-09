# Shared infrastructure

The shared cluster for the apps of nca-apprentices: one Talos node on Hetzner
Cloud, set up by OpenTofu and kept in sync with this repository by Argo CD.

| Path        | What it is                                                             |
| ----------- | ---------------------------------------------------------------------- |
| `tofu/`     | Network, firewall, volume, node, and DNS                               |
| `talos/`    | Machine configuration                                                  |
| `cluster/`  | Argo CD: the platform, and one directory per app environment           |
| `secrets/`  | SOPS-encrypted credentials                                             |
| `docs/`     | [Operating it](docs/operations.md), [first install](docs/bootstrap.md) |

Apprentices start with [the guide for apprentices](docs/onboarding.md).

Apps run from released charts only. `docs/operations.md` describes:

- [Adding an app](docs/operations.md#add-an-app-or-an-environment): a new
  directory under `cluster/apps/<app>/<env>/`.
- [Previews](docs/operations.md#previews): a jjforge PR labeled `preview` runs
  its own chart next to dev.
