# Self-contained cash installer input

The first local installer assumed the historical migration had a specific
filename. The Windows checkout did not contain that file, so installation
stopped while reading SQL, before any database changes.

The installer now reads `docs/sql/cash-approval-foundation-source.sql`, supplied
by this patch. The source bytes and existing integrity digest are unchanged.
The original migration filename is no longer required. No migration file or
migration-history entry is added.

Do not execute the source snapshot directly: the installer omits its historical
staff-role replacement and applies the private RPC implementations and public
invoker wrappers. It retains the local container/project checks, transaction,
preconditions and preservation assertions.

After applying this patch, rerun `node scripts/apply-coreaml-cash-local.cjs`,
then `node scripts/verify-coreaml-cash-local.cjs`. The earlier failed file read
does not require database cleanup.
