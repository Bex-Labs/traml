// ======================================================
// CoreAML Transactions Controller
//
// Owns the DOM manipulation, state management, and 
// rendering logic for Transaction Monitoring and Live Feed.
// ======================================================

import { supabase } from "../config.js";
import * as transactionsService from "../services/transactions.service.js";

export async function loadTxMonitoring() {
    try {
        const tbody = document.getElementById('tx-monitoring-body');
        if (!tbody) return;
        
        tbody.innerHTML = '<tr><td colspan="7" class="text-center py-4 text-muted">Synchronizing with ledger...</td></tr>';

        const typeFilter = document.getElementById('tx-type-filter').value;
        const txs = await transactionsService.getMonitoringFeed(typeFilter);

        tbody.innerHTML = '';

        if (txs.length === 0) {
            tbody.innerHTML = '<tr><td colspan="7" class="text-center py-4 text-muted">No transactions found for current filter.</td></tr>';
            document.getElementById('kpi-tx-volume').innerText = '₦0';
            return;
        }

        let recentVolume = 0;
        let behavioralAnomalies = 0;
        const accountVolumes = {};
        const now = new Date();

        txs.forEach(tx => {
            const txDate = new Date(tx.transaction_timestamp);
            const amount = parseFloat(tx.amount);
            const is24h = (now - txDate) / 36e5 <= 24;

            // --- KPI MATHEMATICS & HEURISTICS ---
            if (is24h) {
                recentVolume += amount;

                // TAML-56: Behavioral Anomalies
                const hour = txDate.getHours();
                const isLateNight = hour >= 0 && hour <= 4;
                const isRoundNumber = amount >= 1000000 && amount % 500000 === 0;
                const isJustBelowThreshold = amount > 4900000 && amount < 5000000;

                if (isLateNight || isRoundNumber || isJustBelowThreshold) {
                    behavioralAnomalies++;
                }

                // TAML-54: Cash Concentration 
                if (tx.transaction_type === 'CREDIT' && tx.account_id) {
                    if (!accountVolumes[tx.account_id]) accountVolumes[tx.account_id] = 0;
                    accountVolumes[tx.account_id] += amount;
                }
            }

            // --- ROW RENDERING ---
            const row = document.createElement('tr');
            const formattedDate = txDate.toLocaleDateString() + ' ' + txDate.toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
            
            const cust = tx.accounts?.customers || {};
            const customerId = cust.id; 
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');

            const isCredit = tx.transaction_type === 'CREDIT';
            const amountClass = isCredit ? 'text-success' : 'text-dark';
            const amountPrefix = isCredit ? '+' : '-';
            const formattedAmount = new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(amount);

            row.innerHTML = `
                <td class="px-4 py-3 text-muted small text-nowrap">${formattedDate}</td>
                <td class="py-3 fw-medium text-dark small">${tx.transaction_reference}</td>
                <td class="py-3 text-muted small">${entityName}</td>
                <td class="py-3 text-muted small text-uppercase">API</td> 
                <td class="py-3 text-end fw-bold ${amountClass} small">${amountPrefix} ${formattedAmount}</td>
                <td class="py-3 text-center"><span class="badge bg-success bg-opacity-10 text-success border border-success" style="font-size: 0.65rem;">CLEARED</span></td>
                <td class="px-4 py-3 text-end">
                    <button class="btn btn-sm btn-outline-secondary" onclick="loadCustomerProfile('${customerId}')" title="Inspect Customer">
                        <span class="material-symbols-outlined" style="font-size: 16px;">person_search</span>
                    </button>
                </td>
            `;
            tbody.appendChild(row);
        });

        // --- INJECT LIVE KPIS ---
        const cashConcentrationFlags = Object.values(accountVolumes).filter(vol => vol >= 5000000).length;

        document.getElementById('kpi-tx-volume').innerText = new Intl.NumberFormat('en-NG', { notation: "compact", compactDisplay: "short", style: "currency", currency: "NGN" }).format(recentVolume);
        
        document.getElementById('kpi-tx-anomalies').innerText = behavioralAnomalies;
        document.getElementById('kpi-tx-anomalies').nextElementSibling.innerText = "TAML-56 Engine Active";
        
        document.getElementById('kpi-tx-concentration').innerText = cashConcentrationFlags;
        document.getElementById('kpi-tx-concentration').nextElementSibling.innerText = "TAML-54 Engine Active";

    } catch (err) {
        console.error("Error loading Tx Monitoring:", err);
        document.getElementById('tx-monitoring-body').innerHTML = '<tr><td colspan="7" class="text-center py-4 text-danger small">Failed to load ledger data. Check console.</td></tr>';
    }
}

export async function loadLiveTransactions() {
    try {
        const tbody = document.getElementById('transaction-feed');
        if (!tbody) return;

        tbody.innerHTML = '<tr><td colspan="5" class="text-center py-3 text-muted small"><span class="spinner-border spinner-border-sm me-2"></span>Syncing live stream...</td></tr>';

        const { data: transactions, error } = await supabase
            .from('transactions')
            .select(`
                id, amount, transaction_type, transaction_timestamp, transaction_reference,
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
            const formattedAmount = new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(tx.amount);

            const cust = tx.accounts?.customers || {};
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');
            
            const isCredit = tx.transaction_type === 'CREDIT';
            const amountClass = isCredit ? 'text-success' : 'text-dark';
            const amountPrefix = isCredit ? '+' : '-';

            row.innerHTML = `
                <td class="px-4 py-3 text-muted small">${timeString}</td>
                <td class="py-3">
                    <div class="fw-bold text-dark small">${tx.transaction_reference}</div>
                    <div class="text-muted text-uppercase" style="font-size: 0.7rem;">${entityName}</div>
                </td>
                <td class="py-3 fw-semibold ${amountClass} small">${amountPrefix} ${formattedAmount}</td>
                <td class="py-3">
                    <span class="badge bg-light text-dark border border-secondary border-opacity-25">${tx.transaction_type || 'SYSTEM'}</span>
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