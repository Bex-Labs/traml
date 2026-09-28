ALTER TABLE public.aml_rules
DROP CONSTRAINT aml_rules_condition_type_check;

ALTER TABLE public.aml_rules
ADD CONSTRAINT aml_rules_condition_type_check
CHECK (
    condition_type IN (
        'AMOUNT_ABOVE',
        'STRUCTURING_PATTERN',
        'VELOCITY_COUNT',
        'BEHAVIORAL_VELOCITY',
        'STATIC_THRESHOLD',
        'DORMANT_ACCOUNT_ACTIVITY'
    )
);