# Upgrade scripts

mpd is still in active development, and the main codebase carries **no
migration code** — bootstrap, `mpd --vm-setup` and the rest converge a VM onto
the *current* layout without carrying logic to rewrite older ones. Fresh
adoptions always land on the latest shape; keeping the shipped path free of
migration cruft is deliberate.

Occasionally a change can't reach an *already-adopted* VM through a normal
`update`/re-`adopt` alone — something baked into a runtime's home at create
time, say, or a hand-managed file. For those special cases, a one-off script
lands here.

## Running them

Run from the host where **mpd-virt** is installed (macOS or Linux) — not from
inside a VM. They drive the fleet through `mpd-virt` and `ssh`, the same as any
other management command. Each takes the VM id:

```
./upgrade/01-bashrc-include.sh <NNN>
```

The numeric prefix (`01-`, `02-`, …) is run order — not to be confused with
`<NNN>`, the VM id passed as the argument. If you're bringing an old VM all the
way up to date, run the scripts in ascending order. Each is idempotent and safe
to re-run, and targets one VM at a time.

Once your fleet is across, a script here has done its job — it stays only as a
record of what the migration was.
