import pandas as pd
import uuid
import random
from datetime import timedelta

print("🕵️ Booting Sentinel AML Typology Injector...")

# 1. Load the existing data
try:
    customers = pd.read_csv('customers_final.csv')
    accounts = pd.read_csv('accounts.csv')
    transactions = pd.read_csv('transactions.csv')
    transactions['transaction_timestamp'] = pd.to_datetime(transactions['transaction_timestamp'])
except FileNotFoundError:
    print("❌ ERROR: Missing CSV files. Run the transaction generator first.")
    exit()

suspicious_txns = []

# Find our "Bad Actors"
bad_actors = customers[customers['risk_rating'].isin(['High', 'Very High'])]
if bad_actors.empty:
    bad_actors = customers.sample(20)

print(f"🎯 Targeted {len(bad_actors)} profiles for AML seeding.")

def create_txn(acct_id, amount, txn_type, channel, narration, timestamp):
    return {
        'id': str(uuid.uuid4()),
        'transaction_reference': f"AML-TXN-{uuid.uuid4().hex[:8].upper()}",
        'account_id': acct_id,
        'amount': amount,
        'currency': 'NGN',
        'transaction_type': txn_type,
        'channel': channel,
        'narration': narration,
        'counterparty_name': f"CP-{random.randint(1000,9999)}",
        'counterparty_bank': 'Internal',
        'transaction_timestamp': timestamp
    }

# 2. Typology 1: Structuring (Smurfing)
smurfers = bad_actors[bad_actors['customer_type'] == 'Individual'].head(5)
for _, smurfer in smurfers.iterrows():
    acct = accounts[accounts['customer_id'] == smurfer['id']].iloc[0]
    base_time = pd.to_datetime('2023-10-15 09:00:00') 
    for i in range(4):
        suspicious_txns.append(create_txn(acct['id'], 4950000.00, 'CREDIT', 'BRANCH', 'Cash Deposit', base_time + timedelta(hours=i*5)))

# 3. Typology 2: Velocity Spikes (Account Takeover / Mule)
mules = bad_actors.sample(3)
for _, mule in mules.iterrows():
    acct = accounts[accounts['customer_id'] == mule['id']].iloc[0]
    base_time = pd.to_datetime('2023-11-01 14:00:00')
    for i in range(20):
        suspicious_txns.append(create_txn(acct['id'], random.uniform(50000, 150000), 'CREDIT', 'MOBILE', 'Inward Transfer', base_time + timedelta(minutes=i*4)))

# 4. Typology 3: Round-Tripping (Corporate Fraud)
corps = bad_actors[bad_actors['customer_type'] == 'Corporate'].head(2)
for _, corp in corps.iterrows():
    acct = accounts[accounts['customer_id'] == corp['id']].iloc[0]
    base_time = pd.to_datetime('2023-12-10 10:00:00')
    suspicious_txns.append(create_txn(acct['id'], 50000000.00, 'DEBIT', 'WEB', 'Vendor Payment Out', base_time))
    suspicious_txns.append(create_txn(acct['id'], 49500000.00, 'CREDIT', 'WEB', 'Refund/Consulting In', base_time + timedelta(hours=18)))

# 5. Typology 4: Cash Concentration (NEW)
# Target: 2 Individuals. Action: 15 large POS/ATM cash deposits in 3 days.
cash_hoarders = customers[customers['customer_type'] == 'Individual'].sample(2)
for _, hoarder in cash_hoarders.iterrows():
    acct = accounts[accounts['customer_id'] == hoarder['id']].iloc[0]
    base_time = pd.to_datetime('2024-01-05 08:00:00')
    for i in range(15):
        channel = random.choices(['POS', 'ATM'], weights=[0.7, 0.3])[0]
        suspicious_txns.append(create_txn(acct['id'], random.uniform(500000, 2000000), 'CREDIT', channel, 'Cash Deposit', base_time + timedelta(hours=i*4)))

# Append and save
print(f"💉 Injecting {len(suspicious_txns)} illicit transactions into the ledger...")
suspicious_df = pd.DataFrame(suspicious_txns)
transactions = pd.concat([transactions, suspicious_df], ignore_index=True)
transactions = transactions.sort_values('transaction_timestamp')
transactions.to_csv('transactions.csv', index=False)

print("🚨 SUCCESS! TAML-21 Completed. All 4 Typologies Injected.")