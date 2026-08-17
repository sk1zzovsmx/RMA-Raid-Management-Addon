# Phase 8: Contract and Evidence Baseline - Context

**Gathered:** 2026-08-17
**Status:** Ready for planning

<domain>
## Phase Boundary

Freeze reproducible compatibility evidence and unambiguous decision rules for the two independent v1.2 dependency candidates before any candidate implementation, runtime cutover, TOC cleanup, or vendored-directory removal can occur.

This phase delivers the shared evidence policy, immutable baseline manifest, machine-verifiable golden fixtures, and separate LibDeflate and talent-stack decision dossiers. It does not implement a replacement, modify addon runtime behavior, edit or remove vendored sources, change the TOC, or make the final KEEP/REPLACE decisions assigned to later phases.

</domain>

<decisions>
## Implementation Decisions

### Evidence artifact organization
- Create one shared baseline manifest plus two independent decision dossiers: one for LibDeflate and one for the atomic talent stack.
- The shared manifest owns the canonical definitions of `AUTOMATED`, `OBSERVED`, and `DEFERRED`; the dossiers reference that policy rather than redefining it.
- Keep the human decision narrative concise in Markdown and store deterministic vectors/results in machine-readable fixtures suitable for automated comparison.
- Every evidence item records its source, relevant hash, and a reproducible command or procedure. A single opaque whole-baseline digest is insufficient provenance.
- The two dossiers remain independent: evidence or a KEEP result in one does not determine or block the other.

### Golden-vector custody
- Commit golden fixtures to the repository so the compatibility oracle survives a later approved vendor removal.
- Generate the initial expected results from the exact untouched vendored implementation and record the vendor hash. External specifications support interpretation but do not replace the shipped vendor as the compatibility authority.
- Record the exact result class and value for malformed decoder inputs, including returned data, `nil`, or error behavior. A boolean success/failure summary is insufficient.
- Use synthetic but representative RMA payload fixtures. Do not capture or commit player names, account data, SavedVariables contents, loot records, or raw client traffic containing personal data.
- The fixtures must preserve enough provenance to be regenerated and independently checked without letting a candidate implementation define its own expected values.

### KEEP/REPLACE decision rules
- Any required gate that fails or is not executed produces `KEEP` for that candidate. Missing proof never authorizes removal.
- The first incompatible counterexample stops the candidate cutover path and is recorded as the smallest reproducible case. Do not continue implementation merely to accumulate more failures or enter an unbounded repair loop.
- A KEEP result is final for v1.2 and counts as a successful evidence-backed milestone outcome. Reconsideration requires a future milestone with new evidence.
- Classify every live gate explicitly as `removal-blocking` or `final-only`. An unexecuted or failed removal-blocking gate forces KEEP; a final-only gate remains visible for the selected-tree compatibility phase and cannot be mislabeled PASS.
- Each dossier must end with one formal, unambiguous disposition contract. Permanent dual implementations, compatibility fallbacks, partial talent-stack removal, and conditional REPLACE results are not valid outcomes.

### Baseline identity and invalidation
- Anchor the baseline to one immutable runtime commit and record individual hashes for every candidate vendor rather than relying on the working tree or declared version strings alone.
- Invalidate affected evidence when a covered vendor, proprietary call site, protocol/serialization/checksum boundary, or talent/inspect path changes.
- Invalidation is targeted: regenerate the affected dossier and update the shared manifest. Unrelated documentation or code changes do not invalidate otherwise unchanged evidence.
- Preserve superseded baselines as history and identify explicitly which later baseline replaces them. Never silently overwrite or delete an earlier evidence record.
- Final compatibility evidence must still target the actual selected runtime tree; a valid Phase 8 baseline does not authorize later reuse after a covered surface changes.

### Codex's Discretion
- Exact artifact filenames and the machine-readable fixture format, provided the shared-manifest/two-dossier structure and provenance rules remain clear.
- Exact command wrappers and fixture grouping, provided they run under the existing repository tooling and do not add a new framework or runtime dependency.
- Selection of the immutable current-runtime anchor commit, with evidence that it represents the shipped v1.1 runtime before v1.2 runtime work.
- Exact inventory layout for vendor hashes, TOC positions, proprietary call sites, and gate classifications.
- Which live checks are `removal-blocking` versus `final-only`, constrained by REQUIREMENTS.md and research: any observation required to prove safe removal must be removal-blocking.

</decisions>

<specifics>
## Specific Ideas

- The manifest should let a reviewer answer four questions quickly: what exact runtime/vendor bytes form the oracle, how each fixture was produced, which dossier consumes it, and what change invalidates it.
- LibDeflate fixtures must outlive a possible Phase 9 directory removal; they therefore cannot be generated only at test runtime from the vendor.
- Talent evidence may include machine-readable characterization results and live procedures, but a mocked or automated result remains `AUTOMATED` and never becomes an `OBSERVED` client result.
- A KEEP dossier should preserve the first minimal counterexample or missing removal-blocking observation so a future milestone knows exactly what new evidence would be required.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.planning/research/SUMMARY.md`, `FEATURES.md`, `ARCHITECTURE.md`, `STACK.md`, and `PITFALLS.md`: already inventory the candidate surfaces, risks, required behaviors, and recommended proof-before-cutover ordering.
- `Raid Management Addon/Raid Management Addon.toc`: authoritative load order for LibDeflate, CallbackHandler, LibBabble-TalentTree, LibTalentQuery, and LibGroupTalents.
- `Raid Management Addon/Libs/LibDeflate/LibDeflate.lua`: untouched 1.0.2 compatibility oracle for addon-channel encode/decode and Adler32.
- `Raid Management Addon/Libs/LibTalentQuery-1.0/LibTalentQuery-1.0.lua` and `LibGroupTalents-1.0/LibGroupTalents-1.0.lua`: untouched revision 84 and revision 65 behavior oracles; LibBabble supplies the associated localized talent-tree data.
- `tests/lua/harness/20_raid_database.lua`, `40_inspect_foundations.lua`, and `70_raid_sync.lua`: existing owners for protocol bytes, vendored talent integration, and inspect coordination behavior.
- Phase 4 and Phase 7 acceptance artifacts: established repository patterns for immutable commit ranges, reproducible commands, protected-surface inventories, and honest `AUTOMATED`/`OBSERVED`/`DEFERRED` dispositions.

### Established Patterns
- `Modules/Comms.lua` consumes only LibDeflate addon-channel encode/decode around unchanged LibSerialize output; `Database/DBRaidEvents.lua` consumes Adler32 for raid UIDs and canonical state digests.
- `Services/SpecInspect.lua` is the sole proprietary adapter to LibGroupTalents and LibTalentQuery, while `Services/InspectCoordinator.lua` owns the client-global inspect target and equipment/talent exclusion.
- Prior milestone evidence is anchored to exact commits and is superseded after later runtime repairs rather than silently reused.
- Live evidence is accepted only from an executed client procedure; unavailable checks stay deferred, unpassed, and visible.
- Vendored sources remain untouched during evaluation and may be deleted only after a later replacement gate passes.

### Integration Points
- Place all Phase 8 manifests, dossiers, procedures, and fixture provenance under `.planning/phases/08-contract-and-evidence-baseline/` unless a machine fixture belongs beside an existing test owner for direct execution.
- Extend the existing Lua/Python harness only to capture stable characterization evidence; Phase 8 must not introduce candidate production code.
- Reference the current v1.2 requirements and roadmap so EVID-01, EVID-02, and EVID-03 each have a visible owner and verification path.
- Make later Phase 9 and Phase 10 plans consume the frozen artifacts rather than rediscovering or redefining their compatibility contracts.

</code_context>

<deferred>
## Deferred Ideas

None. Discussion remained within Phase 8. Candidate implementations, runtime cutovers, TOC changes, vendored-directory removal, and final selected-tree acceptance remain assigned to Phases 9-12.

</deferred>

---

*Phase: 08-contract-and-evidence-baseline*
*Context gathered: 2026-08-17*
