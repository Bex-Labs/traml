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
        customerAlerts
    ] = await Promise.all([
        customers.getById(customerId),
        risk.getInvestigationProfile(customerId),
        alerts.getByCustomer(customerId)
    ]);

    // ==================================================
    // 2. Compute investigation metrics
    // ==================================================

    const metrics = 
    buildMetrics(customerAlerts);

    // ==================================================
    // 3. Compute investigation assessment
    // ==================================================

    const assessment =
    buildAssessment(riskProfile, customerAlerts);

    // ==================================================
    // 4. Build investigation timeline
    // ==================================================

    const timeline =
    buildTimeline(customerAlerts);

    // ==================================================
    // 5. Return investigation model
    // ==================================================

    return {

        customer,

        profile: {

            risk: riskProfile,

            alerts: customerAlerts

        },

        metrics,

        assessment,

        timeline

    };

}

function buildMetrics(customerAlerts) {

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
            ).length

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

function buildTimeline(customerAlerts) {

    return customerAlerts.map(alert => ({

        type: "ALERT",

        timestamp: alert.created_at,

        title: alert.alert_ref,

        severity: alert.severity,

        status: alert.status,

        data: alert

    }));

}