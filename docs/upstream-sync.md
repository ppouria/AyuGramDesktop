# Upstream synchronization

This fork keeps three distinct Git remotes:

| Remote | Repository | Purpose |
| --- | --- | --- |
| `origin` | `ppouria/AyuGramDesktop` | This maintained fork |
| `ayugram` | `AyuGram/AyuGramDesktop` | AyuGram changes |
| `telegram` | `telegramdesktop/tdesktop` | Official Telegram Desktop updates |

Configure a fresh clone with:

```sh
git remote add ayugram https://github.com/AyuGram/AyuGramDesktop.git
git remote add telegram https://github.com/telegramdesktop/tdesktop.git
git fetch ayugram dev
git fetch telegram dev
```

The `Sync Telegram upstream` workflow runs daily and on demand. It mirrors
`telegram/dev` to `upstream/telegram-dev`, tries a merge from the current
`origin/dev`, and opens or updates a pull request when the merge is clean. If
Git reports conflicts, the workflow opens or updates an issue instead of
choosing one side and silently dropping changes.

Resolve a conflicting sync locally with:

```sh
git fetch origin dev
git fetch telegram dev
git switch --force-create sync/telegram-dev origin/dev
git merge --no-ff telegram/dev
git add <resolved-paths>
git commit
git push --force-with-lease origin sync/telegram-dev
```

The open `sync/telegram-dev` pull request updates after the push. Merge it only
after the Windows, macOS, and Linux workflows pass.
