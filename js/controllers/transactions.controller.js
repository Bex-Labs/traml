import {escapeRecord as e} from './customer-records.controller.js';
import {supabase} from '../config.js';
import {getVerifiedSession} from '../services/auth.service.js';
import {createIntelligenceService} from '../services/intelligence.service.js';
import {createLedgerController} from './intelligence.controller.js';
let ledger;
function controller(){const root=document.getElementById('tx-monitoring-root');if(!root)return null;if(!ledger)ledger=createLedgerController(root,createIntelligenceService(supabase,getVerifiedSession),{onCustomer:id=>window.loadCustomerProfile(id)});return ledger;}
export function openTxMonitoring(params={}){return controller()?.open(params);}
export function clearTxMonitoring(){ledger?.clear();}
export function loadTxMonitoring(){const view=document.getElementById('view-tx-monitoring');if(view?.classList.contains('d-none'))return;return controller()?.refresh();}

export async function loadLiveTransactions() {
    try {
        const tbody = document.getElementById('transaction-feed');
        if (!tbody) return;

        tbody.innerHTML = '<tr><td colspan="5" class="text-center py-3 text-muted small"><span class="spinner-border spinner-border-sm me-2"></span>Syncing live stream...</td></tr>';

        const { data: transactions, error } = await supabase
            .from('transactions')
            .select(`
                id, amount, currency, transaction_type, transaction_timestamp, transaction_reference,
                accounts ( customers ( id, entity_name, first_name, last_name ) )
            `)
            .order('transaction_timestamp', { ascending: false })
            .limit(5);

        if (error) throw error;
        tbody.innerHTML = '';

        if (transactions.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="text-center py-3 text-muted small">No recent transactions.</td></tr>';
            return;
        }

        transactions.forEach(tx => {
            const row = document.createElement('tr');
            const dateObj = new Date(tx.transaction_timestamp);
            const timeString = dateObj.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
            const formattedAmount = new Intl.NumberFormat('en-NG', { style: 'currency', currency: tx.currency || 'XXX' }).format(tx.amount);

            const cust = tx.accounts?.customers || {};
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');
            
            const isCredit = tx.transaction_type === 'CREDIT';
            const amountClass = isCredit ? 'text-success' : 'text-dark';
            const amountPrefix = isCredit ? '+' : '-';

            row.innerHTML = `
                <td class="px-4 py-3 text-muted small">${timeString}</td>
                <td class="py-3">
                    <div class="fw-bold text-dark small">${e(tx.transaction_reference)}</div>
                    <div class="text-muted text-uppercase" style="font-size: 0.7rem;">${e(entityName)}</div>
                </td>
                <td class="py-3 fw-semibold ${amountClass} small">${amountPrefix} ${formattedAmount}</td>
                <td class="py-3">
                    <span class="badge bg-light text-dark border border-secondary border-opacity-25">${e(tx.transaction_type || 'SYSTEM')}</span>
                </td>
                <td class="px-4 py-3 text-end">
                    <span class="text-success small fw-bold text-uppercase">Logged</span>
                </td>
            `;
            tbody.appendChild(row);
        });

    } catch (err) {
        console.error("Error loading live transactions:", err);
        document.getElementById('transaction-feed').innerHTML = 
            '<tr><td colspan="5" class="text-center py-3 text-danger small">Stream sync failed.</td></tr>';
    }
}