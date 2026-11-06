# Backend support for homeowner acquisition

Home Blueprint earns useful home records through everyday homeowner utility. The app stores owner data
locally; the public helper supplies content that can be maintained independently of an iPhone release.
The embedded app key controls helper usage. It is not a homeowner identity or authorization to read a home.

| Feature | Implemented support | Deployment or integration boundary |
|---|---|---|
| Next recommended action and scheduled tasks | Local deterministic ranking over the current home's records, dates and owner choices; existing SQLite repositories and reminders | Ranking does not upload task text or prioritize paid referrals |
| Recommended work, DIY readiness and shopping | Validated backend catalog for six recommendations, priced guides, dated sources, supplies and public directories; bundled fallback and cached refresh; local inventory matching | Saved stock counts and selected purchases remain owner-controlled |
| Custom work estimates | Local measurable scope and itemized calculation, separate DIY/pro worksheets, atomic storage, whole-job/itemized exclusivity, exact-currency export | Catalog includes the existing custom scope and trade guides; current worksheet defaults remain bundled, not dynamically replaced |
| Home improvement history and CSV capture | Reviewed import mappings, duplicate detection, actual vs estimated costs, original date precision and transactional persistence | Files-provider selection is a user-selected import, not continuous Drive/Dropbox account synchronization |
| Documents, permits and OCR | Private originals and reviewed extracted facts on the device, linked records and source access | Property document originals and metadata remain device-only; no server OCR or unattended document upload |
| Data portability | Existing home CSV export now includes both custom estimate worksheets and exact line/scope/source data | Export intentionally contains private notes; the owner controls sharing. This is distinct from the selective paid Home Brief |
| Existing private iCloud sync | Household-zone and parent validation, immutable household ownership, safe numeric handling, downloaded asset hash/length/type checks and cold-cache transaction fix | TestFlight uses `HOME_CLOUD_SYNC=NO`; these checks do not enable production CloudKit or make device-only tables sync |
| Home Brief billing | Verified StoreKit 2 entitlement, purchase/restore/refund handling; locally generated selected record PDF | Apple agreement, product review and physical-account release checks remain independent of the helper |
| Feedback | Durable on-device retry queue; server UUID idempotency, conflict detection, bounded request limiting and private admin access | Additive PostgreSQL migration preserves existing reports; original clients remain compatible |
| Contractor and financing referrals | Public directories and owner-controlled quote requests; explicit name/URL/disclosure required for a configured partner | Paid agreements, underwriting/lead APIs and partner consent are not configured |
| Redfin handoff | Owner-controlled export and Home Brief preserve useful evidence for a later seller conversation | No Redfin account/data API or automatic transfer is implemented. Connecting homes requires real account identity, scoped consent and partner access |

## Operational checks

The server suite covers HTTP authorization and conditional requests, malformed catalogs, feedback migration,
concurrent retry deduplication and conflicts against disposable PostgreSQL 17. Swift tests cover catalog
parity/validation/cache recovery, request privacy, cross-household sync rejection, attachment integrity and
custom worksheet export. Existing iPhone journey, StoreKit and unsigned archive checks remain the release gate.

Public content can deploy independently of Apple signing. The read-only TestFlight status workflow checks
current certificate and bundle-registration access separately from build inventory. The account holder
accepted the updated Apple agreement on November 6, 2026, and both signing access checks subsequently passed.
The upload workflow still verifies signing, archives the app and waits for Apple transport acceptance;
processing and tester availability are checked afterward.
