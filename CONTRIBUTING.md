# Contributing

LocalSync is being prepared for its first standalone source release. The owner
must select a license before accepting external code contributions.

## Development loop

1. Install Dart and Node with npm (versions are recorded in the root README).
2. Run `./tool/gate.sh` from the root to install dependencies, generate fixtures,
   analyze and test the framework.
3. Change the responsible package and add coverage at the layer that owns the
   behavior. [Testing](docs/testing.md) explains the boundaries.
4. Run the gate and `./examples/round-trip/run.sh` before proposing the change.

Keep runtime algorithms handwritten and generated declarations disposable.
Application-specific authentication, databases, scopes and business rules belong
in consumers. Never introduce a dependency on a particular application.

Generated conformance output, package caches, database files, and build artifacts
are ignored. Commit source definitions and their mutation history; keep lockfiles
for reproducible dependency resolution. Do not manually edit generated output.

Include what changed, why, and the commands you ran in a pull request. A local
passing run is distinct from a CI result on another operating system or SDK.
