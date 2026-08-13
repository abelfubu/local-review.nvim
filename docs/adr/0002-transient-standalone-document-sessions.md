# Use transient sessions for standalone documents

Files outside Git worktrees are standalone document review targets rather than non-Git repositories. Their sessions live only for the current editor process, survive window and buffer closure, and never acquire repository or branch identity; this supports one-time review of temporary plans without weakening durable branch-bound repository rules. Source-range, overlap, stale-finding, copy, completion, and discard rules still apply, and deleting the document makes its findings stale.

Existing persisted non-Git scopes remain readable through a compatibility path but are not extended or migrated into durable standalone sessions. Once their findings are completed or discarded, no persisted non-Git session is recreated.
