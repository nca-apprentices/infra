# Disk encryption

`talos/talconfig.yaml` asks for LUKS2 on the data volume and on the system
disk's `STATE` and `EPHEMERAL` partitions. Talos encrypts a volume only when
it creates it, so the setting takes effect the next time a node is built, as
in [bootstrap.md](bootstrap.md). The node running now predates it and keeps
its volumes in plain text. Don't run `talosctl apply-config` with this
configuration on it: its volumes would no longer mount.

The key derives from the server's ID, since Hetzner Cloud has no TPM. It
protects a disk or a volume read on another machine, such as a failed disk
that leaves the data center. It doesn't protect against anyone who can boot
the server, such as a holder of the Hetzner API token through the rescue
system, or against Hetzner, which knows the ID. The machine configuration
also sits in plain text in the server's Hetzner user data.
