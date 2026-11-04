-- Commit this enum addition before using the new label in another migration.
ALTER TYPE public.account_status ADD VALUE IF NOT EXISTS 'PENDING';
