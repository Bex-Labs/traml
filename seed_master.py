import os
import uuid
from datetime import datetime
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

def clean_database():
    print("🧹 Cleaning existing data for an idempotent run...")
    # Delete in reverse order of foreign keys to prevent constraint violations
    try:
        supabase.table("alerts").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
        supabase.table("transactions").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
        supabase.table("accounts").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
        supabase.table("customers").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
        print("✅ Database wiped clean.")
    except Exception as e:
        print(f"⚠️ Note during cleanup: {e}")

def seed_data_pipeline():
    print("👤 Seeding customers...")
    customer_1_id = str(uuid.uuid4())
    customer_2_id = str(uuid.uuid4())

    customers = [
        {"id": customer_1_id, "entity_name": "Zenith Trading Ltd", "customer_type": "Corporate", "industry": "Import/Export", "geography": "Lagos, NG", "risk_score": 92, "risk_tier": "HIGH"},
        {"id": customer_2_id, "entity_name": "Abuja Gold Exchange", "customer_type": "Corporate", "industry": "Precious Metals", "geography": "Abuja, NG", "risk_score": 88, "risk_tier": "HIGH"}
    ]
    supabase.table("customers").insert(customers).execute()

    print("🏦 Seeding accounts...")
    account_1_id = str(uuid.uuid4())
    account_2_id = str(uuid.uuid4())
    
    # We now inject the exact time into the 'opened_at' column to satisfy the database constraint
    accounts = [
        {
            "id": account_1_id, 
            "customer_id": customer_1_id, 
            "account_number": "0098123456", 
            "account_type": "Corporate Current",
            "opened_at": datetime.utcnow().isoformat()
        },
        {
            "id": account_2_id, 
            "customer_id": customer_2_id, 
            "account_number": "0098987654", 
            "account_type": "Corporate Current",
            "opened_at": datetime.utcnow().isoformat()
        }
    ]
    supabase.table("accounts").insert(accounts).execute()

    print("💸 Seeding transactions...")
    tx_1_id = str(uuid.uuid4())
    tx_2_id = str(uuid.uuid4())

    transactions = [
        {
            "id": tx_1_id, 
            "account_id": account_1_id, 
            "amount": 45500000.00, 
            "transaction_type": "CREDIT",
            "transaction_timestamp": datetime.utcnow().isoformat(), # <-- Changed from timestamp
            "transaction_reference": f"TXN-{uuid.uuid4().hex[:8].upper()}",
            "channel": "WEB"  
        },
        {
            "id": tx_2_id, 
            "account_id": account_2_id, 
            "amount": 4900000.00, 
            "transaction_type": "CREDIT",
            "transaction_timestamp": datetime.utcnow().isoformat(), # <-- Changed from timestamp
            "transaction_reference": f"TXN-{uuid.uuid4().hex[:8].upper()}",
            "channel": "BRANCH"  
        }
    ]
    supabase.table("transactions").insert(transactions).execute()

    print("🚨 Seeding triggered alerts...")
    alerts = [
        {
            "alert_ref": "ALT-8091",
            "customer_id": customer_1_id,
            "transaction_id": tx_1_id,
            "rule_triggered": "Round-Tripping Detected",
            "severity": "CRITICAL",
            "status": "UNASSIGNED",
            "details": "₦45.5M out, ₦45M returned within 24hrs."
        },
        {
            "alert_ref": "ALT-8092",
            "customer_id": customer_2_id,
            "transaction_id": tx_2_id,
            "rule_triggered": "Structuring / Smurfing Detected",
            "severity": "CRITICAL",
            "status": "UNASSIGNED",
            "details": "Transaction just under NFIU ₦5M reporting threshold."
        }
    ]
    supabase.table("alerts").insert(alerts).execute()
    print("✅ All data seeded successfully.")

if __name__ == "__main__":
    print("🚀 Starting Master Seed Process...")
    clean_database()
    seed_data_pipeline()
    print("🎉 TAML-23 Execution Complete. Environment is ready for the UI.")