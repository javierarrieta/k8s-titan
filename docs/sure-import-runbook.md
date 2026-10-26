# Sure — importing CSV history

For when a bank account exists in Sure but its history does not, and the transaction feed
does not reach far enough back (or does not carry that account at all).

Read §1 and §2 before touching anything. They decide whether the import is correct or
permanently wrong, and nothing downstream will tell you.

Everything about Sure below is read from the pinned upstream source (`app/models/import*`,
`app/models/entry.rb`, `app/models/account.rb`) unless marked **measured**, which means
observed on this cluster with the Revolut export of 2026-10-25.

---

## 1. The rule that decides everything

**Sure cannot deduplicate a CSV row against anything.**

```ruby
# app/models/entry.rb
validates :external_id, uniqueness: { scope: [ :account_id, :source ] },
                        if: -> { external_id.present? && source.present? }
```

backed by a partial unique index on `(account_id, source, external_id) WHERE external_id IS
NOT NULL AND source IS NOT NULL`. Provider rows carry both; CSV rows carry neither, so they
are invisible to the guard. Two consequences, both silent:

- Importing an overlapping period **twice** creates duplicates, not a merge.
- Importing a period a **provider** also serves creates duplicates too, in whichever
  direction you did it first.

So every import needs a date boundary, and the boundary must be stated before the file is
built. §2 computes it.

## 2. Where the boundary goes

If the account is fed by a provider (SimpleFIN via Synci here), the provider owns a rolling
window and the CSV owns everything before it:

```
CSV owns  ────────────────────────────────┤ cutoff ├──── provider owns
                                          first_sync − retention
```

| plan | retention | cutoff for a first sync on 2026-10-25 |
| --- | --- | --- |
| Synci Basic | 60 days | 2026-08-26 |
| Synci Pro | 730 days | 2024-10-25 |

The cutoff is relative to **the day the provider connection was made**, not today. If the
connection is a week older than the CSV you generate, you get a seven-day hole or a
seven-day overlap, and the overlap is the worse of the two because it looks fine.

If the account is manual — nothing feeds it — the CSV owns everything and there is no
cutoff. Just never import the same period twice.

## 3. Which accounts can receive a CSV at all

The import wizard only offers **manual** accounts:

```ruby
# app/models/account.rb
scope :manual, -> {
  left_joins(:account_providers)
    .where(account_providers: { id: nil })
    .where(plaid_account_id: nil, simplefin_account_id: nil)
}
```

An account linked to SimpleFIN cannot be chosen as an import target, and that is not a bug
to work around: §1 means a hand-imported row inside a provider-owned account can never be
reconciled with what the provider re-serves. If the account you want to backfill is
provider-owned, the real options are to accept the shorter history, raise the provider's
retention, or unlink it and own it by hand. Splitting one bank account across a manual
account and a synced one is possible and will skew every report you then read.

**measured:** the Revolut connection exposes one account per currency wallet — eight of
them, named `EUR`, `EUR`, `USD`, `USD`, `GBP`, `CHF`, `CZK`, `CAD`. Revolut savings, pockets
and investments are not in the feed at all: PSD2 covers payment accounts, and a Pocket is a
labelled sub-wallet rather than an account. Those are manual accounts, so they are exactly
the ones a CSV import is for.

## 4. Getting the export

Revolut's export is phone-only and lands in Google Drive rather than downloading, which is
the whole reason this is unpleasant: **export on the phone → Drive → download**.

The export is one file covering every product, `;`-delimited, with a `Product` column
(`Current`, `Deposit`) and a `State` column. **measured** for the 2026-10-25 export: 2,717
rows, of which 2,132 `Current` and 585 `Deposit`, and 61 rows in `REVERTED` or `PENDING`
that must not be imported.

## 5. Convert it

```sh
python3 tools/revolut-export-to-sure.py --in revolut.csv --out-dir /tmp/sure
```

Add `--cutoff YYYY-MM-DD` for any account a provider also feeds (§2). The script writes one
file per product, in Sure's own column names:

```
date;amount;name;currency;tags;notes;account
```

Three things it fixes, because all three fail quietly:

- **Timestamps.** `Date.strptime` matches the configured format exactly, so
  `2026-10-25 14:02:31` against a date-only format does not truncate — the row fails
  validation and you get a rejection wall that reads like a formatting problem.
- **`REVERTED` / `PENDING` rows.** They carry amounts and would import as real money.
- **The `account` column.** Sure matches it against existing account names, exactly, so the
  generated names have to be the names in Sure. Pass `--account-prefix` if yours differ, or
  rename the accounts to match.

The script prints, per file: row count, net amount, date range, and **the `Balance` of the
last kept row**. Write that number down; §7 is about it.

**measured** on the 2026-10-25 export, Basic cutoff 2026-08-26: `Current` 2,003 rows ending
at balance 273.83 EUR; `Deposit` 506 rows ending at 54,634.18 EUR. With the Pro cutoff
(2024-10-25) `Current` is 1,370 rows at 128.42 EUR and `Deposit` produces nothing at all —
its first transaction is 2025-07-18, so the provider owns that account entirely and
importing it would be a pure duplicate.

## 6. Run the import

One file covers many accounts. `Import` is `belongs_to :account, optional: true` — pick an
account in the wizard and every row goes there, which is the one-file-per-account mode you
do not want. Leave it unset and Sure maps per row instead:

```ruby
# app/models/import/account_mapping.rb
def self.mappables_by_key(import)
  unique_values = import.rows.map(&:account).uniq
  accounts = import.family.accounts.where(name: unique_values).index_by(&:name)
  unique_values.index_with { |value| accounts[value] }
end
```

Exact name match, case and spacing included. Unmatched values are not lost: the wizard lists
each distinct value with its row count and offers a dropdown of existing manual accounts, or
"Add as new account". Fixing a spelling there is fine; getting it right in the file is better.

Then, in order: **Settings/Accounts → Import** (`/imports/new`) → upload the file →
**configuration** → **clean** → **confirm** → publish. On the configuration step:

| field | what to set | why it matters |
| --- | --- | --- |
| Column separator | `;` | the script writes semicolons |
| Date format | `YYYY-MM-DD` | must match the file exactly, see §5 |
| Signage convention | `inflows_positive` if amounts already carry their sign | `SIGNAGE_CONVENTIONS = %w[inflows_positive inflows_negative]`; the wrong one turns every payment into income |
| Account | **leave empty** | §6 above |

Use the **clean** preview before confirming. It is where a wrong separator or date format
becomes visible as empty columns instead of as two thousand rows in the wrong account.

## 7. Verify — do not skip this

Compare, per account:

1. Sure's account balance against the **`Balance` of the last row** the script printed.
   Equal means no rows were dropped. Unequal means some were, and the difference is usually
   divisible down to a handful of rows you can find by amount.
2. Transaction count in Sure against the row count the script printed.
3. The earliest transaction date, which must be the first date in the file — not the cutoff,
   not the sync date.

A balance that agrees is the only proof that matters. Everything else in this runbook is
preliminary to it.

## 8. Rollback

`PUT /imports/:id/revert` → `Import#revert` destroys the accounts and entries the import
created, in one transaction, and there is a `RevertImportJob` for the async path. It is
clean, which is more than can be said for deleting rows by hand. Revert the whole import
rather than pruning rows: hand-deleting is how you end up with a balance that no longer
reconciles and no record of why.

## 9. After the import: let the free classifier do the second pass

Categorization is a rule action, and the cheap rules should sit **above** the AI one, because
whichever runs first takes the transaction — both act on `enrichable(:category_id)`, i.e.
"category still nil".

Creating a rule does not touch existing transactions. To sweep the backlog, use **Apply** on
the rule (or **Apply all**), which runs it over existing matches with
`ignore_attribute_locks: true`.

The naive-Bayes classifier refuses to label anything until it has
`MIN_TRAINING_TRANSACTIONS = 20` across `MIN_CATEGORIES = 2` labeled transactions, and only
labels what it scores above `threshold: 0.7`. So a freshly imported backlog is best
sequenced: hand-label a few dozen of the most frequent merchants, Apply, and let Bayes take
the recurring tail for free before spending any LLM calls on the residue.

## 10. What this runbook does not prove

- The UI wording is from the routes and controllers, not from clicking through the live
  instance. Route names (`/imports/new`, upload → configuration → clean → confirm) are
  exact; button labels may not be.
- The measured numbers are for one export on one day. They are an example of the arithmetic,
  not a target.
- Nothing here checks that the provider's window actually starts where you think it does.
  If a sync silently serves less than its advertised retention, the hole is in the middle of
  your history and only the §7 balance check will find it.
