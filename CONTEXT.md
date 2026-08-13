# Local Review

Local Review supports human-led code review sessions whose findings can be completed by handing them to a recipient or publishing them to another review system.

## Language

**Review Session**:
A destination-neutral collection of review findings authored by one reviewer for exactly one review target. A repository review session is the single active, unnamed, durable session for one repository and one reviewed branch; while detached, it should be bound to one commit (detached-commit binding is deferred to repository-continuity work). It survives editor restarts and may become unavailable when branch continuity is lost. A standalone document review session is transient, belongs to one real text file outside any Git worktree, survives closing its window or buffer during the current editor process, and does not survive editor exit. Either kind ends only through atomic completion or when its final finding is discarded. Unavailability is distinct from the staleness of individual findings.
_Avoid_: Review, annotation set

**Review Target**:
Exactly one body of text examined in a review session: either a repository at one branch or detached commit, or one standalone document. The target determines the session's identity, lifetime, availability, and source boundary.
_Avoid_: Scope, project

**Standalone Document**:
A real text file outside every Git worktree reviewed independently of any repository or branch. Its review session is transient but is not tied to the lifetime of a window or buffer; deleting the document makes its findings stale.
_Avoid_: Non-Git repository, temporary repository

**Reviewer**:
The human who examines source code and authors review findings.
_Avoid_: User, author

**Review Finding**:
Non-empty feedback identified during a review session and attached to an exclusive source range. A finding remains active until the session completes or the reviewer explicitly discards it; it may become an agent instruction or a comment in an external review system. Discard supports short-lived undo but no durable history; findings are handed off in repository-path and source-range order.
_Avoid_: Comment, annotation, feedback item

**Recipient**:
A human or coding agent expected to act on review findings.
_Avoid_: Destination, consumer

**Destination**:
The channel through which a completed review session is handed off or published, such as the system clipboard or a submitted GitHub pull request review. A destination must represent every source range without changing its meaning. Clipboard registers are adapters for one system-clipboard destination.
_Avoid_: Recipient

**Source Range**:
A contiguous sequence of lines in a real text file targeted exclusively by one review finding; source ranges cannot overlap, even when a finding is stale. Its identity comes from captured source text and surrounding context rather than exact text or line numbers alone, and the whole range becomes uncertain if either boundary is lost. A reviewer may retarget a finding when the replacement range does not conflict with another finding; ranges that overlap after reconciliation put both findings in conflict.
_Avoid_: Location, selection, line

**Repository**:
The body of source files in one Git working tree being reviewed together. Each Git worktree is a separate repository boundary; Git common-directory identity helps recover continuity when a working tree moves. A file outside every Git worktree is a standalone document, not a repository.
_Avoid_: Scope, project, workspace

**Fresh Finding**:
A review finding whose complete source range can be identified confidently. Retargeting to a confidently identified source range can restore a stale finding to this state.
_Avoid_: Valid comment

**Stale Finding**:
A review finding whose complete source range or file can no longer be identified confidently and therefore requires retargeting before a recipient acts on it. A finding follows a renamed file only when rename continuity is unambiguous and its range reconciles.
_Avoid_: Invalid comment, orphan

**Completion**:
The atomic handoff or publication of every fresh, conflict-free review finding as one self-contained payload through one compatible destination. The session is validated and frozen, then source identity is verified immediately before delivery. One confirmed system-clipboard write or confirmed external submission is sufficient; creating a pending external review is not. Completion removes all findings without retaining local history. Partial copies are non-destructive and never complete a session. An ambiguous external outcome keeps the session and a pending-publication marker until reconciled; a definite side-effect-free failure permits a new attempt after source reconciliation. Whole-session discard requires explicit confirmation and is not completion.
_Avoid_: Export, consume, clear

**Finding Copy**:
A snapshot of some or all review findings that leaves the review session unchanged. It may include stale or conflicted findings and may be made while the session is unavailable, provided those conditions and the reviewed branch are clearly identified.
_Avoid_: Partial completion, preserved export

**Review Summary**:
Optional, non-blank session-level context handed off with the findings through any destination. It is not attached to a source range and becomes the review body when published to a pull request.
_Avoid_: General finding, review body

**Finding Conflict**:
Competing edits or edit-versus-discard actions on the same review finding, competing review summaries, or source ranges that overlap after reconciliation. It blocks session completion until the reviewer explicitly resolves the competing content, action, or targets.
_Avoid_: Stale finding, latest version

**Review Outcome**:
The overall disposition selected when publishing a session as a pull request review: comment, approve, or request changes. Comment is the neutral default; an outcome is never inferred from finding text, approval may include informational findings, and unsupported outcomes are unavailable rather than silently downgraded.
_Avoid_: Finding type, status
