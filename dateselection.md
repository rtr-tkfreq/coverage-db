# Date selection for coverage layers

`tileurl` accumulates one row per date a layer has ever been rendered for —
old dates' tiles are never deleted (see README.md's "How data flows..."). A
layer with more than one published date can now be viewed at any of them,
not just the latest, and a clicked point's details always match whichever
date is currently on screen.

Default behavior is unchanged: with only one published date (the normal
case), nothing new appears and the map shows exactly what it always did.

## Backend (`coverage-db`)

### `api.layer_tileurl(cov_layer)`

Previously returned only the single latest date (`ORDER BY date DESC LIMIT
1`). Now returns every published date for the resolved layer, newest first,
with no `LIMIT`. The resolution logic itself (own tileurl rows vs. falling
back through `cov_layer_source` for a pure alias) is unchanged — only the
`LIMIT 1` was removed.

The frontend still defaults to the first (newest) row, so this is backwards
compatible with any caller that only ever reads index 0.

Migration: `postgresql/migrate_layer_tileurl_all_dates.sql`.

### `api.cov_layer(cov_longitude, cov_latitude, cov_layer, cov_date)`

Gained a fourth parameter, `cov_date date DEFAULT NULL`, so a point clicked
while an older date is selected for display reports that same date's
coverage data instead of always today's true latest.

Resolution per `(operator, reference)` changed from "the true latest
`tileurl` date" to "the latest `tileurl` date at or before `cov_date`" (via
`DISTINCT ON`, replacing the previous `max(date)` grouping), falling back to
the true latest when `cov_date` is `NULL`. Omitting `cov_date` entirely
preserves the exact old behavior.

**Why "at or before", not an exact match:** a combined layer's dependencies
(e.g. `all3600mhz`'s A1TA/TMA/H3A) each have their own independent date
history — the combined layer's own `tileurl.date` is just the max across
them at render time, not a shared timestamp all dependencies actually share.
Requiring an exact match would show blank data for any dependency whose own
history doesn't happen to contain that exact date, even though its data was
genuinely still current as of that snapshot. "At or before" instead lets
every dependency show whatever was actually current for it as of the
selected date — verified with two operators on non-overlapping date
histories (one with a single date, one with two), confirming both the
older-dependency and current-dependency cases resolve correctly at every
`cov_date` tested.

**Migration gotcha:** adding a parameter makes this a distinct function
signature as far as Postgres overload resolution is concerned.
`CREATE OR REPLACE FUNCTION` with the new signature does **not** replace an
existing 3-argument version — it adds a second overload alongside it, and
PostgREST then fails every call with "function is not unique" because a
3-argument call matches both. `postgresql/migrate_cov_layer_date.sql`
therefore `DROP FUNCTION`s the old 3-argument signature first, then creates
the 4-argument one and re-grants `EXECUTE` to `web_anon` (a new overload
needs its own grant — it doesn't inherit the old one's). This was caught by
actually reproducing the ambiguous-overload error against a test database
seeded with the old signature before fixing it, not just reasoned about.

Migration: `postgresql/migrate_cov_layer_date.sql`.

## Frontend (`coverage-website`)

`src/app/frqmap/frqmap.component.ts`:

- New state: `availableDates: LayerConfiguration[]` (every date `reloadMap()`
  fetched for the selected layer, newest first) and
  `selectedDate: string | null` (which one is currently displayed).
- `reloadMap()` stores the full response in `availableDates` and still
  defaults the display to `configs[0]` (the newest) — the unchanged default
  behavior.
- New `selectDate()`: switches the displayed tile overlay to whichever date
  is now selected. Purely client-side — `reloadMap()` already fetched every
  available date's URL in the one `layer_tileurl` call, so switching dates
  needs no new HTTP request.
- `loadCoverageForPoint()` now passes `cov_date` (the map's current
  `selectedDate`) to `/api/rpc/cov_layer`, so point-info always matches the
  displayed tiles. The parameter is omitted entirely (not sent as an empty
  string) when `selectedDate` is unset, so the backend's own
  `cov_date DEFAULT NULL` (= latest) applies.

`src/app/frqmap/frqmap.component.html`:

- New `<select>` for the date, shown only when `availableDates.length > 1` —
  invisible in the normal single-date case. Lists dates newest-first
  (matching the backend's order), reusing the existing `@@dateDate`
  ("Datenstand" / "Recency") translation rather than adding a new i18n
  string.

## Verification performed

- SQL: both functions tested directly against a locally loaded
  `frq_scheme.sql` — multi-date leaf layer (ordering, exact-date resolution
  for `api.cov_layer`), pure-alias layer (still returns all of its source's
  dates), and a combined layer with two operators on deliberately
  non-overlapping date histories (each dependency resolves independently and
  correctly at several `cov_date` values).
- Migration correctness: reproduced the ambiguous-overload failure by
  restoring the old 3-argument `api.cov_layer` signature against an
  already-migrated test database, then confirmed `migrate_cov_layer_date.sql`
  leaves exactly one overload behind.
- Frontend: `ng build --configuration production` succeeds for both `de` and
  `en` locale bundles (Angular's AOT template type-checking passes against
  the new component fields/methods).
- Not performed: a live visual check in an actual browser — this sandbox has
  no PostgREST/nginx running and no browser-automation tool is available
  here. Recommend clicking through it once deployed to a real environment.
