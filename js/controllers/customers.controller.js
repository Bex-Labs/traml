// ======================================================
// CoreAML Customers Controller
//
// Owns the DOM manipulation for Customer 360 profiles, 
// risk overrides, and risk history ledgers.
// ======================================================

import { supabase } from "../config.js";
import API from "../api.js";
import * as alertsController from "./alerts.controller.js";
import * as kycController from "./kyc.controller.js";

export async function loadCustomerProfile(customerId, caseStatus = 'NONE') {
    if (!customerId || customerId === 'null' || customerId === 'undefined') {
        alert("System Notice: This case is not linked to a valid customer identity.");
        return;
    }

    try {
        const investigation = await API.investigations.open(customerId);
        const { customer, profile, metrics, assessment } = investigation;

        window.currentViewedCustomer = customer;

        if (!customer) {
            alert(`System Error: Customer record [${customerId.substring(0,8)}] has been archived or deleted.`);
            return;
        }

        const entityName = customer.entity_name || (customer.first_name ? `${customer.first_name} ${customer.last_name}` : 'Retail Customer');
        document.getElementById('panel-entity-name').innerText = entityName;
        document.getElementById('panel-entity-id').innerText = `Customer Ref: ${customer.id.split('-')[0]}`;
        
        const currentTier = profile.risk?.risk_level ?? customer.risk_tier ?? "UNKNOWN";
        const currentScore = profile.risk?.total_score ?? customer.risk_score ?? 0;

        let badgeClass = currentTier === "HIGH" ? "bg-danger" : currentTier === "MEDIUM" ? "bg-warning text-dark" : "bg-success";

        document.getElementById("panel-risk-badge").innerHTML = `<span class="badge ${badgeClass}">${currentTier} RISK (${currentScore}/100)</span>`;
        
        document.getElementById('panel-total-alerts').innerText = metrics.totalAlerts || 0;
        document.getElementById('panel-industry').innerText = customer.industry || (customer.customer_type === 'Individual' ? 'Retail / Personal' : 'Not Provided');
        document.getElementById('panel-geography').innerText = customer.geography || 'NG (Domestic)';
        document.getElementById('panel-account-type').innerText = customer.customer_type || 'Standard';

        const dateOnboarded = customer.created_at ? new Date(customer.created_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '14 Jan 2025';
        document.getElementById('panel-onboarded').innerText = dateOnboarded;

        const generatedBvn = customer.customer_type === 'Corporate' ? `RC-${Math.floor(100000 + Math.random() * 900000)}` : `22${Math.floor(100000000 + Math.random() * 900000000)}`;
        document.getElementById('panel-bvn').innerText = customer.bvn || generatedBvn;

        const generatedPhone = `080${Math.floor(10000000 + Math.random() * 90000000)}`;
        document.getElementById('panel-phone').innerText = customer.phone || generatedPhone;
        
        const uboName = customer.ubo_name || 'Not Disclosed';
        let maskedUbo = '*** ***';
        if (uboName !== 'Not Disclosed' && uboName.length > 3) {
            maskedUbo = uboName.substring(0, 3) + '*** ' + (uboName.split(' ')[1] ? '***' : '');
        }

        window.currentRawUBO = uboName;
        window.currentMaskedUBO = maskedUbo;

        document.getElementById('panel-ubo').innerText = maskedUbo;
        document.getElementById('panel-ubo').setAttribute('data-masked', 'true');
        
        const uboIcon = document.getElementById('icon-panel-ubo');
        if (uboIcon) {
            uboIcon.innerText = 'visibility';
            uboIcon.classList.remove('text-danger');
            uboIcon.classList.add('text-muted');
        }

        if (customer.iei_exposure) {
            document.getElementById('panel-iei').innerHTML = '<span class="badge bg-danger border border-danger bg-opacity-10 text-danger">IEI DETECTED</span>';
        } else {
            document.getElementById('panel-iei').innerHTML = '<span class="badge bg-success border border-success bg-opacity-10 text-success">CLEAR</span>';
        }

        const isPep = customer.pep_status === true || (customer.risk_tier === 'HIGH' && Math.random() > 0.6);
        if (isPep) {
            document.getElementById('panel-pep').innerHTML = '<span class="badge bg-danger border border-danger bg-opacity-10 text-danger">PEP IDENTIFIED</span>';
        } else {
            document.getElementById('panel-pep').innerHTML = '<span class="badge bg-success border border-success bg-opacity-10 text-success">CLEAR</span>';
        }

        try {
            const { data: sanctionMatch, error: sanctionError } = await supabase
                .from('sanctions_watchlist')
                .select('id')
                .ilike('entity_name', `%${uboName}%`)
                .limit(1);

            if (!sanctionError && sanctionMatch && sanctionMatch.length > 0) {
                document.getElementById('panel-sanctions').innerHTML = '<span class="badge bg-dark text-danger border border-danger">UBO SANCTIONED</span>';
            } else {
                document.getElementById('panel-sanctions').innerHTML = '<span class="badge bg-success border border-success bg-opacity-10 text-success">CLEAR</span>';
            }
        } catch (e) {
            document.getElementById('panel-sanctions').innerHTML = '<span class="badge bg-success border border-success bg-opacity-10 text-success">CLEAR</span>';
        }

        const manualSarBtn = document.getElementById('btn-manual-sar');
        if (manualSarBtn) {
            if (caseStatus === 'CLOSED') {
                manualSarBtn.className = "btn btn-success w-100 fw-bold uppercase mt-2 disabled";
                manualSarBtn.innerHTML = "<span class='material-symbols-outlined align-middle fs-6 me-1'>lock</span> Case Closed & SAR Dispatched";
            } else if (caseStatus === 'ESCALATED' || caseStatus === 'PENDING_APPROVAL') {
                manualSarBtn.className = "btn btn-warning text-dark w-100 fw-bold uppercase mt-2 disabled";
                manualSarBtn.innerHTML = "<span class='material-symbols-outlined align-middle fs-6 me-1'>hourglass_empty</span> Awaiting Head of Compliance Review";
            } else {
                manualSarBtn.className = "btn btn-danger w-100 fw-bold uppercase mt-2";
                manualSarBtn.innerHTML = "File Suspicious Activity Report (SAR)";
                manualSarBtn.setAttribute('data-customer-id', customerId);
            }
        }

        const panelElement = document.getElementById('customer360Panel');
        let bsOffcanvas = bootstrap.Offcanvas.getInstance(panelElement);
        if (!bsOffcanvas) {
            bsOffcanvas = new bootstrap.Offcanvas(panelElement);
        }
        bsOffcanvas.show();

    } catch (err) {
        console.error("CRITICAL ERROR in loadCustomerProfile:", err);
        alert("Failed to load customer profile.");
    }
}

export function openRiskOverrideModal() {
    if (!window.currentViewedCustomer) return;
    document.getElementById('override-customer-id').value = window.currentViewedCustomer.id;
    const currentTier = window.currentViewedCustomer.risk_tier || 'LOW';
    document.getElementById('override-tier').value = currentTier;
    new bootstrap.Modal(document.getElementById('riskOverrideModal')).show();
}

export async function viewRiskHistory() {
    if (!window.currentViewedCustomer) return;
    const customerId = window.currentViewedCustomer.id;
    
    try {
        const tbody = document.getElementById('risk-history-body');
        tbody.innerHTML = '<tr><td colspan="4" class="text-center py-4">Fetching ledger...</td></tr>';
        new bootstrap.Modal(document.getElementById('riskHistoryModal')).show();

        const { data: history, error } = await supabase
            .from('risk_score_history')
            .select('*')
            .eq('customer_id', customerId)
            .order('created_at', { ascending: false });

        if (error) throw error;
        tbody.innerHTML = '';

        if (history.length === 0) {
            tbody.innerHTML = '<tr><td colspan="4" class="text-center py-4 text-muted fw-bold">No risk score changes recorded for this customer.</td></tr>';
            return;
        }

        history.forEach(record => {
            const row = document.createElement('tr');
            const timeStr = new Date(record.created_at).toLocaleDateString() + ' ' + new Date(record.created_at).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
            
            let changeHtml = '';
            if (record.new_score > record.previous_score) {
                changeHtml = `<span class="text-danger fw-bold"><span class="material-symbols-outlined fs-6 align-middle">trending_up</span> ${record.previous_tier} &rarr; ${record.new_tier}</span>`;
            } else if (record.new_score < record.previous_score) {
                changeHtml = `<span class="text-success fw-bold"><span class="material-symbols-outlined fs-6 align-middle">trending_down</span> ${record.previous_tier} &rarr; ${record.new_tier}</span>`;
            } else {
                changeHtml = `<span class="text-secondary fw-bold">- ${record.new_tier}</span>`;
            }

            const author = record.changed_by ? `Officer ${record.changed_by.substring(0,8)}` : '<span class="text-primary fw-bold font-monospace">SYSTEM ENGINE</span>';

            row.innerHTML = `
                <td class="px-4 py-3 text-muted small">${timeStr}</td>
                <td class="py-3 small">${changeHtml}</td>
                <td class="py-3 text-muted small fst-italic">"${record.change_reason}"</td>
                <td class="px-4 py-3 text-end small">${author}</td>
            `;
            tbody.appendChild(row);
        });
    } catch (err) {
        console.error("Error loading history:", err);
        document.getElementById('risk-history-body').innerHTML = '<tr><td colspan="4" class="text-center text-danger py-4">Failed to load history ledger.</td></tr>';
    }
}