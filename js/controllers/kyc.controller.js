// ======================================================
// CoreAML KYC Controller
//
// Owns the DOM manipulation, state management, and 
// rendering logic for the KYC & Entity Directory UI.
// ======================================================

import * as customersService from "../services/customers.service.js";

// Encapsulated State
let currentKycFilter = 'ALL';

export async function loadKYCDirectory() {
    try {
        const tbody = document.getElementById('kyc-directory-body');
        if (!tbody) return;

        const filterText = currentKycFilter === 'ALL' ? '' : `${currentKycFilter.toLowerCase()} `;
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted">Loading ${filterText}directory...</td></tr>`;

        // Using the dedicated customer service
        const customers = await customersService.getDirectory(currentKycFilter);

        tbody.innerHTML = '';

        if (!customers || customers.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted">No ${filterText}customers found.</td></tr>`;
            return;
        }

        customers.forEach(cust => {
            const row = document.createElement('tr');
            
            // --- DYNAMIC DAY-0 INHERENT RISK CALCULATION ---
            let score = cust.risk_score;
            if (score === 99 || !score) {
                score = 10; 
                if (cust.kyc_status !== 'COMPLETED') score += 25; 
                if (cust.customer_type === 'Corporate' || cust.registration_number) score += 20; 
                
                const ind = (cust.industry || '').toLowerCase();
                if (['crypto', 'casino', 'betting', 'real estate', 'ngo'].some(i => ind.includes(i))) score += 30; 
                
                score = Math.min(score, 99);
            }

            let riskBadgeColor = 'success';
            let riskText = 'LOW';
            if (score >= 75) { riskBadgeColor = 'danger'; riskText = 'HIGH'; }
            else if (score >= 40) { riskBadgeColor = 'warning'; riskText = 'MEDIUM'; }

            let kycBadge = 'bg-secondary';
            if (cust.kyc_status === 'COMPLETED') kycBadge = 'bg-success';
            else if (cust.kyc_status === 'PENDING') kycBadge = 'bg-warning text-dark';
            
            const kycAction = (cust.kyc_status !== 'COMPLETED') 
                ? `<button class="btn btn-sm btn-outline-info fw-bold" onclick="openKYCVerification('${cust.id}')">Verify ID</button>` 
                : `<button class="btn btn-sm btn-light border text-primary fw-bold uppercase" onclick="loadCustomerProfile('${cust.id}')" style="font-size: 0.7rem;">View Profile</button>`;

            let entityName = cust.company_name || cust.entity_name;
            if (!entityName) {
                entityName = cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Retail Customer';
            }

            const industry = cust.industry || (cust.customer_type === 'Individual' ? 'Retail / Personal' : 'Uncategorized');
            const geography = cust.geography || 'NG (Domestic)';
            
            const idDisplay = cust.registration_number ? `RC: ${cust.registration_number}` : (cust.bvn ? `BVN: ${cust.bvn}` : `ID: ${cust.id.split('-')[0]}`);

            row.innerHTML = `
                <td class="px-4 py-3">
                    <div class="fw-bold text-dark small">${entityName}</div>
                    <div class="text-muted font-monospace" style="font-size: 0.7rem;">${idDisplay}</div>
                </td>
                <td class="py-3">
                    <span class="badge ${kycBadge}">${cust.kyc_status || 'NOT DONE'}</span>
                </td>
                <td class="py-3">
                    <div class="fw-semibold small text-muted">${industry}</div>
                    <div class="text-muted" style="font-size: 0.7rem;">${geography}</div>
                </td>
                <td class="py-3">
                    <span class="badge bg-${riskBadgeColor} bg-opacity-10 text-${riskBadgeColor === 'warning' ? 'dark' : riskBadgeColor} border border-${riskBadgeColor} px-2 py-1">
                        ${riskText} (${score})
                    </span>
                </td>
                <td class="py-3 text-end px-4">${kycAction}</td>
            `;
            tbody.appendChild(row);
        });

    } catch (err) {
        console.error("Error loading KYC Directory:", err);
    }
}

export function switchKycTab(filter, activeBtn) {
    currentKycFilter = filter;
    
    // Reset button styles
    ['tab-kyc-all', 'tab-kyc-pending', 'tab-kyc-completed'].forEach(id => {
        const btn = document.getElementById(id);
        if(btn) {
            btn.classList.remove('btn-dark', 'active');
            btn.classList.add('btn-outline-dark');
        }
    });

    // Set active button style
    activeBtn.classList.remove('btn-outline-dark');
    activeBtn.classList.add('btn-dark', 'active');

    loadKYCDirectory();
}