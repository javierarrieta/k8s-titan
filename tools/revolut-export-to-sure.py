#!/usr/bin/env python3
"""Turn a Revolut account export into Sure TransactionImport CSVs, split per account.

WHY THIS EXISTS. Revolut's export is not importable as-is, and the two failure modes are
quiet. `Date.strptime` in Sure matches the configured format exactly, so a `2026-10-25 14:02:31`
timestamp against a date-only format does not truncate - the row simply fails validation,
and a large export produces a wall of rejected rows that reads like a formatting problem.
`REVERTED` and `PENDING` rows carry amounts and would import as real money. Both have to be
handled before the file reaches the browser.

It also splits by the `Product` column, because Sure matches an import's `account` column
against existing account NAMES, exactly (Import::AccountMapping.mappables_by_key), so the
file has to name the account each row belongs to. One file covers many accounts; one export
per account is not needed.

The report it prints is the point: the `Balance` of the last kept row is what you compare
against Sure after the import. An import that lands on a different number is an import with
rows missing, and this is the only way to know without opening the banking app.

Usage:
    python3 tools/revolut-export-to-sure.py --in revolut.csv --out-dir /tmp/sure
    python3 tools/revolut-export-to-sure.py --in revolut.csv --out-dir /tmp/sure --cutoff 2026-08-26

The cutoff is for accounts a provider also feeds. Sure deduplicates provider rows by
(account_id, source, external_id); CSV rows have none of those, so an overlapping period
becomes duplicates rather than a merge. Import everything up to the cutoff and let the
provider own everything after it.
"""

import argparse
import csv
import os
import sys

REQUIRED = ["Completed Date", "State", "Product", "Amount", "Description", "Currency", "Type"]

# Sure's TransactionImport column names. Anything else is ignored silently, which is
# how a file that "imported fine" ends up with no names on it.
OUT_COLUMNS = ["date", "amount", "name", "currency", "tags", "notes", "account"]

# Account names Sure is given, per Revolut product. Keep in step with the names actually
# used in Sure; a mismatch is not an error, it is a dropdown you have to fix by hand.
PRODUCT_TO_ACCOUNT = {"Current": "Revolut Current", "Deposit": "Revolut Deposit"}


def detect_delimiter(sample):
    return ";" if sample.count(";") >= sample.count(",") else ","


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="infile", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--cutoff", help="YYYY-MM-DD; keep rows dated on or before this")
    ap.add_argument("--account-prefix", default="", help="prefix for generated account names")
    args = ap.parse_args()

    with open(args.infile, newline="", encoding="utf-8-sig") as fh:
        head = fh.readline()
        delim = detect_delimiter(head)
        fh.seek(0)
        reader = csv.DictReader(fh, delimiter=delim)
        missing = [c for c in REQUIRED if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"missing required column(s) {missing}; found {reader.fieldnames}")
        rows = list(reader)

    dropped_state = [r for r in rows if r["State"] != "COMPLETED"]
    kept = [r for r in rows if r["State"] == "COMPLETED"]
    dropped_cutoff = []
    if args.cutoff:
        dropped_cutoff = [r for r in kept if r["Completed Date"][:10] > args.cutoff]
        kept = [r for r in kept if r["Completed Date"][:10] <= args.cutoff]

    os.makedirs(args.out_dir, exist_ok=True)
    print(f"source rows: {len(rows)}   delimiter: {delim!r}")
    print(f"dropped non-COMPLETED (PENDING/REVERTED/etc): {len(dropped_state)}")
    if args.cutoff:
        print(f"dropped after cutoff {args.cutoff}: {len(dropped_cutoff)}")

    for product in sorted({r["Product"] for r in kept}):
        sub = sorted((r for r in kept if r["Product"] == product), key=lambda r: r["Completed Date"])
        if not sub:
            continue
        account = args.account_prefix + PRODUCT_TO_ACCOUNT.get(product, f"Revolut {product}")
        out_path = os.path.join(args.out_dir, f"sure-{product.lower()}.csv")
        with open(out_path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh, delimiter=";")
            w.writerow(OUT_COLUMNS)
            for r in sub:
                notes = f"Revolut fee {r['Fee']}" if r.get("Fee") not in (None, "", "0", "0.00") else ""
                w.writerow([
                    r["Completed Date"].split(" ")[0],  # date only; a time component fails validation
                    r["Amount"],
                    r["Description"],
                    r["Currency"],
                    r["Type"],                          # Topup / Transfer / Exchange / Card Payment ...
                    notes,
                    account,
                ])
        net = sum(float(r["Amount"]) for r in sub)
        print(f"\n{out_path}")
        print(f"  rows: {len(sub)}   net: {net:+.2f} {sub[0]['Currency']}")
        print(f"  range: {sub[0]['Completed Date'][:10]} .. {sub[-1]['Completed Date'][:10]}")
        print(f"  account column: {account!r}  (must match the account name in Sure exactly)")
        print(f"  VERIFY: balance on the last row is {sub[-1]['Balance']} - Sure must agree after import")


if __name__ == "__main__":
    main()
