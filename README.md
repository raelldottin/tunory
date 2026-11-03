# tunory

## Product roadmap

See the [full Tunory product roadmap](docs/product-roadmap.md) for the local-library foundation, playlist duplicate cleanup, AI and voice-driven curation, Apple Music and Spotify provider plans, phased acceptance criteria, and release gates.

## Deployment

See [Tunory deployment requirements](docs/deployment-requirements.md) for platform
and distribution choices, signing and artifact requirements, release gates, and
the evidence required before a build reaches testers or customers.

## Apple Music API prototype

Tunory's Apple Music integration was proven end-to-end by building the playlist **"After Hours — Violin & Trumpet"** entirely through the official Apple Music REST API: 17 exact catalog recordings added to My Library and appended to the existing playlist in exact order, with zero duplicates and independent read-back verification (Catalog 17/17, Library 17/17, Playlist 17/17).

Working artifacts live in `Tools/AppleMusicAPI/` (signed `AMHelper.app`, `orchestrate.py`, `devtoken.py`).

Full engineering history, failure analysis, and operational runbook: [docs/apple-music-integration-retrospective.md](docs/apple-music-integration-retrospective.md).
