# Contributing

Thanks for helping. A few things to know:

- **Build and test:** `make test` runs the test suites and `make install` builds and installs your copy. The Xcode Command Line Tools are enough. [docs/GUIDE.md](docs/GUIDE.md#building) has the details.
- **How it fits together:** read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before a larger change, and [docs/EXTENDING.md](docs/EXTENDING.md) before touching the extension API.
- **Conventions:** [CLAUDE.md](CLAUDE.md) lists them (it's written for coding agents, and works for people too). In short: a minimal core, features that only some people want go in an extension, new saved fields are optional, and docs stay current with behavior.
- **Pull requests:** keep them focused, include tests for logic that doesn't need a window, and say how you checked the change in the app.
- **Bugs and ideas:** use the issue forms; questions go to Discussions.
