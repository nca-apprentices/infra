# Disk encryption

The node runs without disk encryption. Talos encrypts a volume only when it
creates it, so encryption arrives with the next node built from scratch, as
in [bootstrap.md](bootstrap.md). Before that build, add LUKS2 to the data
volume in `talos/talconfig.yaml`, and to the system disk's `STATE` and
`EPHEMERAL` partitions:

```yaml
    userVolumes:
      - name: data
        provisioning: ...
        encryption: &luks
          provider: luks2
          keys:
            - slot: 0
              nodeID: {}
    volumes:
      - name: STATE
        encryption: *luks
      - name: EPHEMERAL
        encryption: *luks
```

Never apply it to a node whose volumes exist: they would no longer mount.

The key derives from the server's ID, since Hetzner Cloud has no TPM. It
protects a disk or a volume read on another machine, such as a failed disk
that leaves the data center. It doesn't protect against anyone who can boot
the server, such as a holder of the Hetzner API token through the rescue
system, or against Hetzner, which knows the ID. The machine configuration
also sits in plain text in the server's Hetzner user data.
