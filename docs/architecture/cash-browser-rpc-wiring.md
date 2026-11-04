# Align the uploaded banking page with the installed cash foundation

The uploaded Windows page still used legacy direct transaction inserts and
OVR-prefixed vault requests. This explains why the contract test encountered
`supabase.from`: its deliberately limited cash RPC mock exposed a real source
mismatch, not a missing read-only mock.

The teller now calls post_cash_transaction for both ordinary postings and
high-value requests. Manager cash requests are read from
cash_transaction_approvals; their references, directions and requester IDs appear
in the queue. Manager decisions call review_cash_transaction. Historical OVR
vault rows are not converted or replayed. Normal vault operations stay separate.

The patch is based on the uploaded core-banking.html and touches only cash
submission, cash queue data/rendering and cash review. Existing onboarding,
KYC lookup and other page changes are retained. No database changes are needed.

The contract test now explicitly rejects the legacy table-write handlers and
also executes the actual manager queue with separate cash/vault fixtures. It
checks that a cash approval appears and an old OVR vault row does not appear in
the cash queue. All SDK responses in this contract test are mocked; the native
browser suite still needs a successful run on the local stack.
