import pandas as pd
import random
import uuid
from datetime import datetime, timedelta

print("🚀 Booting Sentinel AML Transaction Engine...")

# 1. Load the customer data you generated
try:
    customers_df = pd.read_csv('sentinel_aml_customers.csv')
    print(f"✅ Loaded {len(customers_df)} customers.")
except FileNotFoundError:
    print("❌ ERROR: Could not find 'sentinel_aml_customers.csv'. Make sure it's in the same folder!")
    exit()

# 2. Add UUIDs to Customers (To match TAML-26 Schema)
customers_df['id'] = [str(uuid.uuid4()) for _ in range(len(customers_df))]

# Prep arrays for accounts and transactions
accounts = []
transactions = []

# Time bounds: Last 6 months
end_date = datetime.now()
start_date = end_date - timedelta(days=180)

# Transaction Context Generators
channels = ['WEB', 'MOBILE', 'ATM', 'POS', 'BRANCH', 'USSD']
individual_narrations = ['Groceries', 'Utility Bill', 'Airtime Recharge', 'Transfer to Family', 'Salary Credit', 'Netflix Subscription', 'POS Withdrawal']
corporate_narrations = ['Vendor Payment', 'Payroll Disbursement', 'Office Supplies', 'Consulting Fees', 'Tax Payment', 'Client Invoice Settlement']
banks = ['Zenith Bank', 'GTBank', 'Access Bank', 'First Bank', 'UBA', 'Stanbic IBTC']

def random_date(start, end):
    delta = end - start
    random_days = random.randrange(delta.days)
    random_seconds = random.randrange(24*60*60)
    return start + timedelta(days=random_days, seconds=random_seconds)

print("⚙️ Generating Accounts and 6-Month Transaction Ledger (This will take a few seconds)...")

# 3. The Core Generation Loop
for index, row in customers_df.iterrows():
    # --- A. CREATE ACCOUNT ---
    account_id = str(uuid.uuid4())
    account_num = f"0{random.randint(100000000, 999999999)}" # 10 digit NUBAN
    
    is_corp = row['customer_type'] == 'Corporate'
    acct_type = 'CURRENT' if is_corp else random.choice(['SAVINGS', 'CURRENT'])
    
    accounts.append({
        'id': account_id,
        'customer_id': row['id'],
        'account_number': account_num,
        'account_type': acct_type,
        'currency': 'NGN',
        'status': 'ACTIVE',
        'opened_at': (start_date - timedelta(days=random.randint(100, 1000))).strftime('%Y-%m-%d')
    })
    
    # --- B. CREATE TRANSACTIONS ---
    # Individuals: ~5-20 txns/month (30 to 120 total)
    # Corporates: ~20-50 txns/month (120 to 300 total)
    txn_count = random.randint(120, 300) if is_corp else random.randint(30, 120)
    
    for _ in range(txn_count):
        txn_type = random.choices(['CREDIT', 'DEBIT'], weights=[0.4, 0.6])[0]
        channel = random.choices(channels, weights=[0.2, 0.4, 0.1, 0.15, 0.05, 0.1])[0]
        
        # Plausible amounts
        if is_corp:
            amount = round(random.uniform(50000, 5000000), 2)
            narration = random.choice(corporate_narrations)
        else:
            amount = round(random.uniform(1000, 250000), 2)
            narration = random.choice(individual_narrations)
            
        transactions.append({
            'id': str(uuid.uuid4()),
            'transaction_reference': f"TXN-{uuid.uuid4().hex[:12].upper()}",
            'account_id': account_id,
            'amount': amount,
            'currency': 'NGN',
            'transaction_type': txn_type,
            'channel': channel,
            'narration': narration,
            'counterparty_name': f"CP-{random.randint(1000,9999)}",
            'counterparty_bank': random.choice(banks) if channel in ['WEB', 'MOBILE'] else 'Internal',
            'transaction_timestamp': random_date(start_date, end_date).strftime('%Y-%m-%d %H:%M:%S')
        })

# 4. Save everything to CSV files
print("💾 Saving files to disk...")

# Overwrite customer file to include the new UUIDs
customers_df.to_csv('customers_final.csv', index=False)

# Save Accounts
pd.DataFrame(accounts).to_csv('accounts.csv', index=False)

# Save Transactions
txn_df = pd.DataFrame(transactions)
# Sort transactions chronologically
txn_df['transaction_timestamp'] = pd.to_datetime(txn_df['transaction_timestamp'])
txn_df = txn_df.sort_values('transaction_timestamp')
txn_df.to_csv('transactions.csv', index=False)

print(f"🎉 SUCCESS! TAML-20 Completed.")
print(f"📊 Generated {len(accounts)} Accounts.")
print(f"📊 Generated {len(transactions):,} Transactions.")