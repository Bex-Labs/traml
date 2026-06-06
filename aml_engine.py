import os
import uuid
import pandas as pd
from supabase import create_client, Client
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

print("🧠 Booting Sentinel AML Rule Evaluation Engine (v1.4 - DB Write + KYC Rule)...")

# --- 1. CONNECT ---
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

if not SUPABASE_URL or not SUPABASE_KEY:
    print("❌ Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in environment.")
    exit()

try:
    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)
    print("✅ Connected to Sentinel Database.")
except Exception as e:
    print(f"❌ Connection failed.\nError: {e}")
    exit()

# --- 2. CONFIGURATION ---
RULE_CONFIG = {
    'single_txn_limit': 5000000.00,
    'cumulative_daily_limit': 10000000.00,

    # TAML-52: Structuring parameters
    'structuring_lower_bound': 4000000.00,
    'structuring_upper_bound': 4999999.99,
    'structuring_count_threshold': 2,
    'structuring_time_window': '24h',

    # TAML-50: Velocity parameters
    'velocity_count_limit': 15,
    'velocity_time_window': '24h',

    # TAML-53: Round-Tripping parameters
    'round_trip_time_window': '24h',
    'round_trip_retention_min': 0.90,
    'round_trip_retention_max': 1.05,
    'round_trip_min_amount': 1000000.00,

    # R-005: KYC parameters
    # CBN Tier 1 limit — transactions above this require verified BVN/KYC
    'kyc_txn_threshold': 50000.00,
}

# --- 3. RULE DIRECTORY ---

def evaluate_all_rules(df, customers_df):
    alerts = []

    df['timestamp'] = pd.to_datetime(df['transaction_timestamp'])
    df = df.sort_values('timestamp')
    df['date'] = df['timestamp'].dt.date

    # --- R-001A: Single Transaction Threshold ---
    print(f"   ↳ [Rule 1A] Checking single transactions >= ₦{RULE_CONFIG['single_txn_limit']:,.2f}...")
    single_flags = df[df['amount'] >= RULE_CONFIG['single_txn_limit']]
    for _, row in single_flags.iterrows():
        alerts.append({
            'transaction_reference': row['transaction_reference'],
            'account_id': row['account_id'],
            'rule_id': 'R-001A',
            'rule_name': 'High Value Single Transaction',
            'severity': 'HIGH',
            'description': f"Amount ₦{row['amount']:,.2f} exceeds reporting limit.",
            'timestamp': row['transaction_timestamp']
        })

    # --- R-001B: Cumulative Daily Threshold ---
    print(f"   ↳ [Rule 1B] Checking cumulative daily totals >= ₦{RULE_CONFIG['cumulative_daily_limit']:,.2f}...")
    daily_totals = df.groupby(['account_id', 'date'])['amount'].sum().reset_index()
    cum_flags = daily_totals[daily_totals['amount'] >= RULE_CONFIG['cumulative_daily_limit']]
    for _, row in cum_flags.iterrows():
        alerts.append({
            'transaction_reference': 'MULTIPLE_TXNS',
            'account_id': row['account_id'],
            'rule_id': 'R-001B',
            'rule_name': 'High Value Cumulative Daily',
            'severity': 'CRITICAL',
            'description': f"Daily volume reached ₦{row['amount']:,.2f}.",
            'timestamp': str(row['date'])
        })

    df_rolling = df.set_index('timestamp')

    # --- R-002: Structuring (TAML-52) ---
    print(f"   ↳ [Rule 2] Checking for Structuring (Rolling {RULE_CONFIG['structuring_time_window']} window)...")
    struct_txns = df_rolling[
        (df_rolling['amount'] >= RULE_CONFIG['structuring_lower_bound']) &
        (df_rolling['amount'] <= RULE_CONFIG['structuring_upper_bound'])
    ]
    if not struct_txns.empty:
        struct_counts = struct_txns.groupby('account_id').rolling(
            RULE_CONFIG['structuring_time_window']
        )['id'].count().reset_index(name='count')
        struct_flags = struct_counts[struct_counts['count'] >= RULE_CONFIG['structuring_count_threshold']]
        struct_flags = struct_flags.drop_duplicates(subset=['account_id'])
        for _, row in struct_flags.iterrows():
            alerts.append({
                'transaction_reference': 'MULTIPLE_TXNS',
                'account_id': row['account_id'],
                'rule_id': 'R-002',
                'rule_name': 'Structuring / Smurfing Detected',
                'severity': 'CRITICAL',
                'description': f"Account made {int(row['count'])} transactions just under the reporting limit within {RULE_CONFIG['structuring_time_window']}.",
                'timestamp': str(row['timestamp'])
            })

    # --- R-003: High Velocity (TAML-50) ---
    print(f"   ↳ [Rule 3] Checking for high transaction velocity (Rolling {RULE_CONFIG['velocity_time_window']} window)...")
    if not df_rolling.empty:
        velocity_counts = df_rolling.groupby('account_id').rolling(
            RULE_CONFIG['velocity_time_window']
        )['id'].count().reset_index(name='txn_count')
        velocity_flags = velocity_counts[velocity_counts['txn_count'] >= RULE_CONFIG['velocity_count_limit']]
        velocity_flags = velocity_flags.drop_duplicates(subset=['account_id'])
        for _, row in velocity_flags.iterrows():
            alerts.append({
                'transaction_reference': 'MULTIPLE_TXNS',
                'account_id': row['account_id'],
                'rule_id': 'R-003',
                'rule_name': 'High Velocity Account',
                'severity': 'MEDIUM',
                'description': f"Account triggered {int(row['txn_count'])} transactions within {RULE_CONFIG['velocity_time_window']}.",
                'timestamp': str(row['timestamp'])
            })

    # --- R-004: Round-Tripping (TAML-53) ---
    print(f"   ↳ [Rule 4] Checking for Round-Tripping patterns...")
    df_out = df[(df['transaction_type'] == 'DEBIT') & (df['amount'] >= RULE_CONFIG['round_trip_min_amount'])]
    df_in  = df[(df['transaction_type'] == 'CREDIT') & (df['amount'] >= RULE_CONFIG['round_trip_min_amount'])]

    rt_merge = pd.merge(df_out, df_in, on='account_id', suffixes=('_out', '_in'))

    if not rt_merge.empty:
        rt_merge['time_diff'] = rt_merge['timestamp_in'] - rt_merge['timestamp_out']
        window_limit = pd.to_timedelta(RULE_CONFIG['round_trip_time_window'])
        valid_time = (rt_merge['time_diff'] > pd.Timedelta(0)) & (rt_merge['time_diff'] <= window_limit)
        valid_amount = (
            (rt_merge['amount_in'] >= rt_merge['amount_out'] * RULE_CONFIG['round_trip_retention_min']) &
            (rt_merge['amount_in'] <= rt_merge['amount_out'] * RULE_CONFIG['round_trip_retention_max'])
        )
        rt_flags = rt_merge[valid_time & valid_amount].drop_duplicates(subset=['transaction_reference_in'])
        for _, row in rt_flags.iterrows():
            alerts.append({
                'transaction_reference': row['transaction_reference_in'],
                'account_id': row['account_id'],
                'rule_id': 'R-004',
                'rule_name': 'Round-Tripping Detected',
                'severity': 'CRITICAL',
                'description': f"₦{row['amount_out']:,.2f} left account and ₦{row['amount_in']:,.2f} returned {row['time_diff']} later.",
                'timestamp': str(row['timestamp_in'])
            })

    # --- R-005: KYC Gap Detection ---
    # Flags accounts whose customer has kyc_status != 'VERIFIED' and is transacting
    # above the CBN Tier 1 threshold (₦50,000). Requires kyc_status column on customers table.
    # SQL to add the column: ALTER TABLE customers ADD COLUMN IF NOT EXISTS kyc_status TEXT NOT NULL DEFAULT 'PENDING';
    print(f"   ↳ [Rule 5] Checking for KYC gaps (threshold ₦{RULE_CONFIG['kyc_txn_threshold']:,.2f})...")

    if customers_df is not None and not customers_df.empty and 'kyc_status' in customers_df.columns:
        unverified = customers_df[customers_df['kyc_status'] != 'VERIFIED'][['id', 'kyc_status']].copy()
        unverified = unverified.rename(columns={'id': 'customer_id'})

        # accounts_df is available in scope via closure from run_engine — passed via df already
        # We need account_id → customer_id map: use df which has account_id, merge with accounts
        if 'customer_id' in df.columns:
            # transactions already have customer_id joined
            txn_with_cust = df
        else:
            # Will be skipped — accounts map is built in run_engine and passed separately
            txn_with_cust = None

        if txn_with_cust is not None:
            flagged_txns = txn_with_cust.merge(unverified, on='customer_id', how='inner')
            flagged_txns = flagged_txns[flagged_txns['amount'] >= RULE_CONFIG['kyc_txn_threshold']]
            # One alert per account, not per transaction
            flagged_accounts = flagged_txns.groupby('account_id').agg(
                txn_count=('id', 'count'),
                max_amount=('amount', 'max'),
                kyc_status=('kyc_status', 'first'),
                customer_id=('customer_id', 'first'),
                latest_timestamp=('transaction_timestamp', 'max')
            ).reset_index()

            for _, row in flagged_accounts.iterrows():
                alerts.append({
                    'transaction_reference': 'MULTIPLE_TXNS',
                    'account_id': row['account_id'],
                    'rule_id': 'R-005',
                    'rule_name': 'KYC Gap — Unverified Customer Transacting',
                    'severity': 'HIGH',
                    'description': (
                        f"Customer KYC status is '{row['kyc_status']}'. "
                        f"{int(row['txn_count'])} transaction(s) above ₦{RULE_CONFIG['kyc_txn_threshold']:,.0f} threshold "
                        f"(largest: ₦{row['max_amount']:,.2f})."
                    ),
                    'timestamp': str(row['latest_timestamp'])
                })
    else:
        print("   ↳ [Rule 5] ⚠️  Skipped — kyc_status column not found on customers table.")
        print("              Run this SQL first: ALTER TABLE customers ADD COLUMN IF NOT EXISTS kyc_status TEXT NOT NULL DEFAULT 'PENDING';")

    return alerts


# --- 4. WRITE ALERTS TO DATABASE ---

def write_alerts_to_db(alerts, accounts_df, transactions_df):
    """
    Transforms engine alerts to match the Supabase alerts table schema and batch-inserts them.

    Engine alert fields:   transaction_reference, account_id, rule_id, rule_name, severity, description, timestamp
    DB alerts table fields: alert_ref, customer_id, transaction_id, rule_triggered, severity, status, details

    Deduplication: alerts with the same (customer_id, rule_triggered) already raised today are skipped,
    so running the engine multiple times in a day does not produce duplicate alerts.
    For a belt-and-suspenders DB-level constraint, run this once in Supabase SQL editor:
        CREATE UNIQUE INDEX IF NOT EXISTS uq_alert_customer_rule_day
        ON alerts (customer_id, rule_triggered, (created_at::date));
    """
    if not alerts:
        return 0

    # Build lookup maps
    # account_id → customer_id
    acct_to_customer = dict(zip(accounts_df['id'], accounts_df['customer_id']))

    # transaction_reference → transaction_id (db UUID)
    ref_to_id = dict(zip(transactions_df['transaction_reference'], transactions_df['id']))

    db_records = []
    for alert in alerts:
        account_id = alert.get('account_id')
        txn_ref    = alert.get('transaction_reference', 'MULTIPLE_TXNS')

        customer_id    = acct_to_customer.get(account_id)
        transaction_id = ref_to_id.get(txn_ref)  # None for MULTIPLE_TXNS — that's fine

        # Skip if we can't resolve the customer (orphaned account — shouldn't happen in clean data)
        if not customer_id:
            print(f"   ⚠️  Skipping alert for account {account_id} — no matching customer found.")
            continue

        db_records.append({
            'alert_ref':      f"ALT-{uuid.uuid4().hex[:6].upper()}",
            'customer_id':    customer_id,
            'transaction_id': transaction_id,
            'rule_triggered': alert['rule_name'],
            'severity':       alert['severity'],
            'status':         'UNASSIGNED',
            'details':        alert['description'],
        })

    if not db_records:
        print("   ⚠️  No valid records to insert after mapping.")
        return 0

    # --- DEDUPLICATION ---
    # Fetch today's existing alerts to avoid duplicates on repeat engine runs.
    today_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0).isoformat()
    print("🔍 Checking for existing alerts today to deduplicate...")
    existing_resp = supabase.table('alerts').select('customer_id, rule_triggered').gte('created_at', today_start).execute()
    existing_fingerprints = set()
    if existing_resp.data:
        for row in existing_resp.data:
            existing_fingerprints.add((row['customer_id'], row['rule_triggered']))

    before_count = len(db_records)
    db_records = [
        r for r in db_records
        if (r['customer_id'], r['rule_triggered']) not in existing_fingerprints
    ]
    skipped = before_count - len(db_records)
    if skipped > 0:
        print(f"   ↳ Skipped {skipped} duplicate alert(s) already raised today.")

    if not db_records:
        print("   ✅ No new alerts to insert — all already exist for today.")
        return 0

    # Batch insert (1,000 rows at a time)
    batch_size = 1000
    inserted   = 0
    print(f"💾 Writing {len(db_records)} new alert(s) to Supabase alerts table...")
    for i in range(0, len(db_records), batch_size):
        batch = db_records[i:i + batch_size]
        supabase.table('alerts').insert(batch).execute()
        inserted += len(batch)
        print(f"   ...inserted {inserted}/{len(db_records)}", end='\r')

    print(f"\n✅ {inserted} alerts written to database.")
    return inserted


# --- 5. ENGINE CORE ---

def fetch_all_rows(table_name, max_rows=50000):
    """Paginates through a Supabase table and returns all rows."""
    rows = []
    start, chunk = 0, 1000
    while start < max_rows:
        response = supabase.table(table_name).select('*').range(start, start + chunk - 1).execute()
        if not response.data:
            break
        rows.extend(response.data)
        start += chunk
        print(f"   ...fetched {len(rows):,} rows from [{table_name}]", end='\r')
    print()
    return rows


def run_engine(mode='batch'):
    print(f"🔍 Initializing Engine in [{mode.upper()}] mode...")

    # --- Fetch transactions ---
    print("⏳ Downloading transaction history...")
    transactions = fetch_all_rows('transactions')
    if not transactions:
        print("⚠️  No transactions found.")
        return

    # --- Fetch accounts (needed for account_id → customer_id mapping) ---
    print("⏳ Downloading accounts...")
    accounts = fetch_all_rows('accounts')
    if not accounts:
        print("⚠️  No accounts found. Cannot map alerts to customers.")
        return

    # --- Fetch customers (needed for R-005 KYC rule) ---
    print("⏳ Downloading customers...")
    customers = fetch_all_rows('customers')
    customers_df = pd.DataFrame(customers) if customers else pd.DataFrame()

    transactions_df = pd.DataFrame(transactions)
    accounts_df     = pd.DataFrame(accounts)

    # Join customer_id onto transactions via accounts so R-005 can use it
    acct_cust_map = accounts_df[['id', 'customer_id']].rename(columns={'id': 'account_id'})
    transactions_df = transactions_df.merge(acct_cust_map, on='account_id', how='left')

    print(f"\n⚙️  Scanning {len(transactions_df):,} transactions against active rule library...\n")

    alerts = evaluate_all_rules(transactions_df, customers_df)

    print(f"\n🚨 Engine Scan Complete. Generated {len(alerts)} total alerts.")

    if alerts:
        alerts_df = pd.DataFrame(alerts)
        print("\n--- 🛑 ALERT SUMMARY BY RULE ---")
        print(alerts_df['rule_name'].value_counts().to_string())

        # Write to Supabase
        write_alerts_to_db(alerts, accounts_df, transactions_df)

        # Also save CSV as local backup
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f'generated_alerts_{timestamp_str}.csv'
        alerts_df.to_csv(filename, index=False)
        print(f"📂 Local backup saved to '{filename}'")


if __name__ == "__main__":
    run_engine(mode='batch')
