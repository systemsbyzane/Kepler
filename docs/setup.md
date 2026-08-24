# Setup

Create a normal Codex project named `Kepler-<company>`. Keep every existing monorepo as its own project. Run `/kepler setup`, review exact project identities and paths, review proposed domains and relationships, correct them, and confirm the ArchitectureMap.

Setup lists saved Codex projects and selects them by opaque runtime ID plus
exact normalized path. It may read selected project shape while proposing the
ArchitectureMap and writes only confirmed Kepler control-project state. It
does not ask for a repositories root, scan for Git repositories, create
workload folders, install bridges, import projects, or modify their source.
Finish with `/kepler doctor`.
