import uuid
from datetime import datetime, timezone
from supabase import create_client, Client

# Hardcoded credentials matching your seed_master.py
url: str = "https://mbwgglgvykjpsnvnvcsj.supabase.co"
key: str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1id2dnbGd2eWtqcHNudm52Y3NqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTE0MjQ5MCwiZXhwIjoyMDk0NzE4NDkwfQ.RTbElP3o6KlI5ebCTue8ZKU9TpKpZsNTdhhsSnuyfps"
supabase: Client = create_client(url, key)

def test_structuring_engine():
    print("🔍 Searching database for a target account...")
    
    # 1. Grab the first available account to use as our test subject
    response = supabase.table("accounts").select("id").limit(1).execute()
    
    if not response.data:
        print("❌ No accounts found. Please run seed_master.py first.")
        return

    target_account_id = response.data[0]['id']
    print(f"🎯 Target Account Acquired: {target_account_id}")
    print("💸 Initiating Smurfing Sequence: Injecting 3x ₦3,000,000 transactions...")

    # 2. Build the structured transactions
    smurf_transactions = []
    for i in range(3):
        smurf_transactions.append({
            "id": str(uuid.uuid4()),
            "account_id": target_account_id,
            "amount": 3000000.00,
            "transaction_type": "CREDIT",
            "transaction_timestamp": datetime.now(timezone.utc).isoformat(),
            "transaction_reference": f"SMURF-{uuid.uuid4().hex[:6].upper()}",
            "channel": "MOBILE"
        })

    # 3. Fire them into the database (This is where your SQL Trigger wakes up!)
    try:
        supabase.table("transactions").insert(smurf_transactions).execute()
        print("✅ Success! Transactions injected.")
        print("🚨 The AML Engine should have intercepted this. Check your UI!")
    except Exception as e:
        print(f"❌ Error injecting transactions: {e}")

if __name__ == "__main__":
    test_structuring_engine()