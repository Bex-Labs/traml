import pandas as pd
from supabase import create_client, Client
import numpy as np
import time

print("🏗️ Booting Sentinel AML REST Ingestion Module...")

# 1. Connect via HTTPS
SUPABASE_URL = ""
SUPABASE_KEY = "" 

try:
    print("🔌 Connecting to Supabase API...")
    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)
    print("✅ Connection Established.")
except Exception as e:
    print(f"❌ Connection failed.\nError: {e}")
    exit()

# 2. Load the CSV Data
print("📂 Loading local datasets...")
customers = pd.read_csv('customers_final.csv')
accounts = pd.read_csv('accounts.csv')
transactions = pd.read_csv('transactions.csv')

# --- 3. TRANSFORMATION LAYER ---
print("🔄 Transforming data to match TAML-26 canonical schema...")

cust_db = pd.DataFrame()
cust_db['id'] = customers['id']
cust_db['customer_type'] = customers['customer_type'].str.upper()

is_ind = customers['customer_type'] == 'Individual'
cust_db['first_name'] = customers.loc[is_ind, 'name'].apply(lambda x: str(x).split(' ')[0] if pd.notna(x) else None)
cust_db['last_name'] = customers.loc[is_ind, 'name'].apply(lambda x: str(x).split(' ', 1)[1] if len(str(x).split(' ')) > 1 else None)
cust_db['company_name'] = customers.loc[~is_ind, 'name']

cust_db['date_of_birth'] = customers.loc[is_ind, 'dob'].replace('N/A', None)
cust_db['bvn'] = customers.loc[is_ind, 'bvn_or_rc']
cust_db['registration_number'] = customers.loc[~is_ind, 'bvn_or_rc']
cust_db['address_line'] = customers['address']
cust_db['industry_code'] = customers['industry_code']
cust_db['risk_tier'] = customers['risk_rating'].str.upper().str.replace(' ', '_')
cust_db['is_pep'] = customers['pep_status'].apply(lambda x: True if str(x) not in ['None', 'nan'] else False)

acc_db = accounts[['id', 'customer_id', 'account_number', 'currency', 'status', 'opened_at']].copy()
acc_db['account_type'] = accounts['account_type'].str.upper()

txn_db = transactions[['id', 'transaction_reference', 'account_id', 'amount', 'currency', 'narration', 'counterparty_name', 'counterparty_bank', 'transaction_timestamp']].copy()
txn_db['transaction_type'] = transactions['transaction_type'].str.upper()
txn_db['channel'] = transactions['channel'].str.upper()

# Convert NaNs to None
cust_db = cust_db.replace({np.nan: None})
acc_db = acc_db.replace({np.nan: None})
txn_db = txn_db.replace({np.nan: None})

cust_records = cust_db.to_dict(orient='records')
acc_records = acc_db.to_dict(orient='records')
txn_records = txn_db.to_dict(orient='records')

# --- 4. BATCH LOAD MODULE (Throttled for Cloud Safety) ---
def insert_in_batches(data, table_name, batch_size=1000):
    print(f"🚀 Pushing {len(data):,} rows to [{table_name}] via REST API...")
    for i in range(0, len(data), batch_size):
        batch = data[i:i + batch_size]
        supabase.table(table_name).upsert(batch).execute()
        print(f"   ...Uploaded rows {i} to {i + len(batch)}")
        time.sleep(0.5) # Gives the Supabase server a 0.5-second breath between chunks

try:
    # 1. Clean the database first (Optional but recommended if you want a fresh start)
    print("🧹 Wiping old data...")
    supabase.table("alerts").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
    supabase.table("transactions").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
    supabase.table("accounts").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
    supabase.table("customers").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()

    # 2. Push the full generated dataset
    print("🚀 Pushing full dataset...")
    insert_in_batches(cust_records, 'customers')
    insert_in_batches(acc_records, 'accounts')
    
    # Push ALL transactions (starting from 0, not 50,000)
    insert_in_batches(txn_records, 'transactions') 
    
    print("\n🎉 ALL DATA INGESTED! Sentinel Sandbox is Live. (TAML-27 Complete)")
except Exception as e:
    print(f"\n❌ Ingestion halted due to API error:\n{e}")
