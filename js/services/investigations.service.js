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
 * Version 1:
 *  - Customer
 *  - Risk
 *
 * Future versions will enrich this object with:
 *  - Alerts
 *  - Transactions
 *  - Accounts
 *  - Intelligence
 *
 * @param {string} customerId
 * @returns {Promise<Object>}
 */
export async function open(customerId) {

    const [

    customer,

    riskProfile,

    customerAlerts

] = await Promise.all([

    customers.getById(customerId),

    risk.getInvestigationProfile(customerId),

    alerts.getByCustomer(customerId)

]);

return {

    customer,

    profile: {

        risk: riskProfile,

        alerts: customerAlerts

    },

    metrics: {

        totalAlerts: customerAlerts.length

    }

};

}