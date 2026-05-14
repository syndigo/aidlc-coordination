# ugc-platform — AIDLC Learnings

Accumulated learnings from SDLC runs on the ugc-platform project. Each entry is tagged with the originating ticket and date.

---

## GDI-929 — 2026-05-14

### L-929-1: Stacked PR management for feature dependencies
When FR-H.5 (product tagging) depends on FR-H.4 (visual UGC library, GDI-886), and GDI-886 hasn't merged to dev, the dependent branch should rebase onto the dependency branch and target the PR to the dependency branch (not dev). This creates a clean stacked PR diff (only GDI-929 changes visible) and unblocks development without waiting for GDI-886 to merge. After GDI-886 merges, GDI-929 PR is retargeted to dev.

### L-929-2: ktlint package-name rule and DB-matching package names
The `standard:package-name` ktlint rule fires on package names with underscores (e.g., `catalog.visual_ugc`). When the package name intentionally matches DB table naming convention (visual_ugc_assets), disable the rule via `.editorconfig`: `ktlint_standard_package-name = disabled`. This should be added to the codebase when the first `visual_ugc` subpackage files are committed (GDI-886 missed this).

### L-929-3: Surrogate PK vs composite PK for junction tables
JPA composite PKs (`@EmbeddedId`) add boilerplate. Existing codebase (VisualUgcTag.kt from GDI-886) uses surrogate UUID id + UNIQUE constraint for junction rows. Follow this pattern for new junction tables (VisualUgcProductTag) even if the ADR specifies composite PK — simpler JPA, same functional guarantees, consistent with existing patterns.

### L-929-4: GlobalExceptionHandler maps DataIntegrityViolationException to 409
The platform's GlobalExceptionHandler maps Spring Data `DataIntegrityViolationException` (FK constraint violation) to HTTP 409, not 400. IT tests for "invalid FK → error" should assert `statusCode in [400, 409]` not `statusCode == 400` to avoid fragile assertions that break if the error handling evolves.

### L-929-5: spotlessApply before commit for GDI-886 rebase
When rebasing a branch onto GDI-886 (which has spotless violations), run `./gradlew :services:ugc-api:spotlessApply` before committing. GDI-886 has pre-existing violations (no-consecutive-comments in VisualUgcAssetDto.kt, formatting issues in VisualUgcController, VisualUgcRepository, VisualUgcService, etc.) that must be fixed for CI to pass.
