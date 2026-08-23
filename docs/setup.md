# Setup

Create a normal Codex project named `Kepler-<company>`. Keep every existing monorepo as its own project. Run `/kepler setup`, review exact project identities and paths, review proposed domains and relationships, correct them, and confirm the ArchitectureMap.

Setup may read repository shape and write only Kepler control-project state plus explicitly approved bridge state. It does not import repositories or modify their source. `bin/kepler architecture confirm FILE` persists a reviewed `kepler.dev/v1` ArchitectureMap. Finish with `/kepler doctor`.
