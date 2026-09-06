# Local viewer (W21)

The numerical viewer is a separate local application. It does not install
anything on a remote host and is not part of the headless helper runtime.

With Nix and the pinned flake:

```sh
nix build .#ejn-viewer
./result/bin/ejn-viewer --demo
```

The demo displays two asymmetric row-major NumPy planes. It is only the V2
window shell; protocol loading, comparisons, and measurements arrive in later
workstreams. A non-GUI smoke check is available for packaging checks:

```sh
QT_QPA_PLATFORM=offscreen ./result/bin/ejn-viewer --smoke-test --offscreen
```

For the graphical acceptance gate, run `ejn-viewer --smoke-test` on an actual
macOS or Linux display and retain the emitted JSON evidence with the display,
scaling, hardware, and timings.

V2 has been visibly exercised on Linux (`DISPLAY=:0`, with a paint/resize/
close smoke result). macOS graphical rendering has not yet been run in this
environment; the `aarch64-darwin` derivation is evaluated by the flake and
still requires an actual macOS display run before the V2 gate is complete.
