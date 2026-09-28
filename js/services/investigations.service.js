// ======================================================
// CoreAML Investigation Service
//
// Orchestrates investigator-ready context by composing
// domain services.
//
// IMPORTANT:
// This service MUST NOT communicate directly with
// Supabase. It composes other services.
// ======================================================

import * as customers from "./customers.service.js";
import * as risk from "./risk.service.js";
import * as alerts from "./alerts.service.js";
import * as transactions from "./transactions.service.js";

/**
 * Open an investigation context.
 *
 * Version 1
 * ----------
 * Composes:
 *  - Customer
 *  - Risk
 *  - Alerts
 *
 * Future versions will enrich this object with:
 *  - Transactions
 *  - Accounts
 *  - Intelligence
 *
 * @param {string} customerId
 * @returns {Promise<Object>}
 */
export async function open(customerId) {

    // ==================================================
    // 1. Gather domain data
    // ==================================================

    const [
    customer,
    riskProfile,
    customerAlerts,
    customerTransactions
] = await Promise.all([
    customers.getById(customerId),
    risk.getInvestigationProfile(customerId),
    alerts.getByCustomer(customerId),
    transactions.getByCustomer(customerId)
]);

    // ==================================================
    // 2. Compute investigation metrics
    // ==================================================

    const metrics = 
    buildMetrics(customerAlerts, customerTransactions);

    // ==================================================
    // 3. Compute investigation assessment
    // ==================================================

    const assessment =
    buildAssessment(riskProfile, customerAlerts);

    // ==================================================
    // 4. Build investigation timeline
    // ==================================================

    const timeline =
    buildTimeline(customerAlerts, customerTransactions);

    // ==================================================
    // 5. Return investigation model
    // ==================================================

    return {

        customer,

        profile: {

            risk: riskProfile,

            alerts: customerAlerts,

            transactions: customerTransactions

        },

        metrics,

        assessment,

        timeline

    };

}

function buildMetrics(customerAlerts, customerTransactions) {

    return {

        totalAlerts: customerAlerts.length,

        openAlerts:
            customerAlerts.filter(alert =>
                alert.status !== "CLOSED"
            ).length,

        investigatingAlerts:
            customerAlerts.filter(alert =>
                alert.status === "INVESTIGATING"
            ).length,

        closedAlerts:
            customerAlerts.filter(alert =>
                alert.status === "CLOSED"
            ).length,

        highSeverityAlerts:
            customerAlerts.filter(alert =>
                alert.severity === "HIGH"
            ).length,
        
        totalTransactions:
            customerTransactions.length,

        transactionVolume:
            customerTransactions.reduce(
                (total, tx) => total + Number(tx.amount || 0),
                0
            ),

        largestTransaction:
            customerTransactions.reduce(
                (largest, tx) =>
                    Math.max(largest, Number(tx.amount || 0)),
                0
            )
    };

}

function buildAssessment(riskProfile, customerAlerts) {

    return {

        priority:
            riskProfile?.risk_level === "HIGH"
                ? "HIGH"
                : customerAlerts.some(alert =>
                    alert.severity === "HIGH"
                )
                    ? "HIGH"
                    : "NORMAL",

        requiresEscalation:
            customerAlerts.some(alert =>
                alert.status === "PENDING_APPROVAL"
            )

    };

}

function buildTimeline(customerAlerts, customerTransactions) {

    const alertEvents = customerAlerts.map(alert => ({

        type: "ALERT",

        timestamp: alert.created_at,

        title: alert.alert_ref,

        severity: alert.severity,

        status: alert.status,

        data: alert

    }));

    const transactionEvents = customerTransactions.map(tx => ({

        type: "TRANSACTION",

        timestamp: tx.transaction_timestamp,

        title: tx.transaction_reference,

        severity: null,

        status: tx.transaction_type,

        data: tx

    }));

    return [

        ...alertEvents,

        ...transactionEvents

    ].sort((a, b) =>

        new Date(b.timestamp) - new Date(a.timestamp)

    );

}