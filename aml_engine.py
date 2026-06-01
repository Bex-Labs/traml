import pandas as pd
from supabase import create_client, Client
from datetime import datetime

print("🧠 Booting Sentinel AML Rule Evaluation Engine (v1.3 - Typology Complete)...")

# 1. Connect via HTTPS
SUPABASE_URL = "https://mbwgglgvykjpsnvnvcsj.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1id2dnbGd2eWtqcHNudm52Y3NqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTE0MjQ5MCwiZXhwIjoyMDk0NzE4NDkwfQ.RTbElP3o6KlI5ebCTue8ZKU9TpKpZsNTdhhsSnuyfps"

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
    'round_trip_time_window': '24h',       # Must return within 24 hours
    'round_trip_retention_min': 0.90,      # Inbound amount is at least 90% of outbound
    'round_trip_retention_max': 1.05,      # Inbound amount is no more than 105% of outbound
    'round_trip_min_amount': 1000000.00    # Only flag large round trips (ignore small refunds)
}

# --- 3. RULE DIRECTORY ---

def evaluate_all_rules(df):
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
    struct_txns = df_rolling[(df_rolling['amount'] >= RULE_CONFIG['structuring_lower_bound']) & 
                             (df_rolling['amount'] <= RULE_CONFIG['structuring_upper_bound'])]
    if not struct_txns.empty:
        struct_counts = struct_txns.groupby('account_id').rolling(RULE_CONFIG['structuring_time_window'])['id'].count().reset_index(name='count')
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
        velocity_counts = df_rolling.groupby('account_id').rolling(RULE_CONFIG['velocity_time_window'])['id'].count().reset_index(name='txn_count')
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
    # Isolate large debits and credits
    df_out = df[(df['transaction_type'] == 'DEBIT') & (df['amount'] >= RULE_CONFIG['round_trip_min_amount'])]
    df_in = df[(df['transaction_type'] == 'CREDIT') & (df['amount'] >= RULE_CONFIG['round_trip_min_amount'])]
    
    # Merge on account_id to find instances where money went out and came back in
    rt_merge = pd.merge(df_out, df_in, on='account_id', suffixes=('_out', '_in'))
    
    if not rt_merge.empty:
        # Calculate time difference between the inbound and outbound transaction
        rt_merge['time_diff'] = rt_merge['timestamp_in'] - rt_merge['timestamp_out']
        
        # Must happen AFTER the debit, but within the time window
        window_limit = pd.to_timedelta(RULE_CONFIG['round_trip_time_window'])
        valid_time = (rt_merge['time_diff'] > pd.Timedelta(0)) & (rt_merge['time_diff'] <= window_limit)
        
        # Inbound amount must be similar to Outbound amount (e.g. 90% - 105%)
        valid_amount = (rt_merge['amount_in'] >= rt_merge['amount_out'] * RULE_CONFIG['round_trip_retention_min']) & \
                       (rt_merge['amount_in'] <= rt_merge['amount_out'] * RULE_CONFIG['round_trip_retention_max'])
        
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

    return alerts

# --- 4. ENGINE CORE ---

def run_engine(mode='batch'):
    print(f"🔍 Initializing Engine in [{mode.upper()}] mode...")
    
    transactions = []
    
    # NEW: Pagination loop to bypass the 1,000 row API limit
    print("⏳ Downloading transaction history...")
    start = 0
    chunk_size = 1000
    
    # We will pull 20,000 rows (20 chunks) which is deep enough to catch our seeded typologies
    while start < 20000:
        response = supabase.table('transactions').select('*').range(start, start + chunk_size - 1).execute()
        if not response.data:
            break
        transactions.extend(response.data)
        start += chunk_size
        print(f"   ...fetched {len(transactions):,} rows", end='\r')
    
    if not transactions:
        print("\n⚠️ No transactions found in database.")
        return

    df = pd.DataFrame(transactions)
    print(f"\n⚙️ Scanning {len(df):,} transactions against active rule library...\n")
    
    alerts = evaluate_all_rules(df)

    print(f"\n🚨 Engine Scan Complete. Generated {len(alerts)} total alerts.")
    
    if alerts:
        alerts_df = pd.DataFrame(alerts)
        print("\n--- 🛑 ALERT SUMMARY BY RULE ---")
        print(alerts_df['rule_name'].value_counts().to_string())
        
        # Safe save with timestamp
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f'generated_alerts_{timestamp_str}.csv'
        alerts_df.to_csv(filename, index=False)
        print(f"\n📂 Saved full alert log to '{filename}'")
if __name__ == "__main__":
    run_engine(mode='batch')