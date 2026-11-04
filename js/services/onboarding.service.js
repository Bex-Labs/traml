// COREAML_ATOMIC_ONBOARDING_V1: orchestration only; authorization is enforced in SQL.
const MAX_FILE_BYTES = 10 * 1024 * 1024;
const MIME_TYPES = new Set(['application/pdf', 'image/jpeg', 'image/png']);

function documentExtension(file) {
    const ext = file?.name?.split('.').pop().toLowerCase();
    if (!file || !['pdf', 'jpg', 'jpeg', 'png'].includes(ext) || !MIME_TYPES.has(file.type)
        || file.size <= 0 || file.size > MAX_FILE_BYTES) {
        throw new Error('Both documents must be PDF, JPG, or PNG files of up to 10 MB each.');
    }
    return ext;
}

export function createOnboardingAttempt(input, tenantId, customerId = crypto.randomUUID()) {
    if (!/^[A-Za-z0-9_-]+$/.test(tenantId || '')) throw new Error('A valid assigned bank is required.');
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(customerId)) throw new Error('Invalid submission reference.');
    const type = input.customerType;
    const firstName = type === 'RETAIL' ? input.firstName?.trim() : null;
    const lastName = type === 'RETAIL' ? input.lastName?.trim() : null;
    const entityName = type === 'CORPORATE' ? input.entityName?.trim() : null;
    const bvn = input.bvn?.trim();
    if (!['RETAIL', 'CORPORATE'].includes(type) || !/^[0-9]{11}$/.test(bvn || '')
        || (type === 'RETAIL' && (!firstName || !lastName)) || (type === 'CORPORATE' && !entityName)) {
        throw new Error('Enter the customer name and an 11-digit BVN.');
    }
    const prefix = `${tenantId}/${customerId}/`;
    const idPath = `${prefix}id_document.${documentExtension(input.idFile)}`;
    const utilityPath = `${prefix}utility_bill.${documentExtension(input.utilityFile)}`;
    return {
        customerId, idFile: input.idFile, utilityFile: input.utilityFile, uploaded: new Set(), rpcStarted: false,
        payload: Object.freeze({ p_customer_id: customerId, p_customer_type: type,
            p_first_name: firstName, p_last_name: lastName, p_entity_name: entityName,
            p_bvn: bvn, p_id_path: idPath, p_utility_path: utilityPath }),
    };
}

export async function submitOnboardingAttempt(client, attempt) {
    const bucket = client.storage.from('kyc-vault');
    async function cleanup() {
        const { error } = await bucket.remove([attempt.payload.p_id_path, attempt.payload.p_utility_path]);
        return error ? ' Some unlinked documents may require administrator cleanup.' : '';
    }
    try {
        for (const [objectPath, file] of [[attempt.payload.p_id_path, attempt.idFile], [attempt.payload.p_utility_path, attempt.utilityFile]]) {
            if (attempt.uploaded.has(objectPath)) continue;
            const { error } = await bucket.upload(objectPath, file, { upsert: false, contentType: file.type });
            // A deterministic path may exist after an interrupted upload. The RPC
            // subsequently verifies ownership; uploaded documents cannot be overwritten.
            if (error && String(error.statusCode) !== '409' && error.error !== 'Duplicate') throw error;
            attempt.uploaded.add(objectPath);
        }
    } catch (error) {
        let warning;
        try { warning = await cleanup(); } catch { warning = ' Document cleanup could not be confirmed.'; }
        throw new Error(`Document upload failed: ${error.message || 'unknown error'}.${warning}`);
    }
    attempt.rpcStarted = true;
    let response;
    try { response = await client.rpc('onboard_customer', attempt.payload); }
    catch (error) {
        const uncertain = new Error(`Submission could not be confirmed. Keep this page open and retry reference ${attempt.customerId}.`);
        uncertain.keepAttempt = true;
        throw uncertain;
    }
    if (response.error) {
        const error = response.error;
        // Without a DB/PostgREST error code, a response may have been lost after
        // commit. Keep documents and reuse the same immutable request on retry.
        if (!error.code) {
            const uncertain = new Error(`Submission could not be confirmed. Keep this page open and retry reference ${attempt.customerId}.`);
            uncertain.keepAttempt = true;
            throw uncertain;
        }
        let lookup;
        try { lookup = await client.from('customers').select('id').eq('id', attempt.customerId).maybeSingle(); }
        catch { lookup = { error: true }; }
        if (lookup.error || lookup.data) {
            const retained = new Error(`${error.message} Submission ${attempt.customerId} needs confirmation; its documents have been retained.`);
            retained.keepAttempt = true;
            throw retained;
        }
        let warning;
        try { warning = await cleanup(); } catch { warning = ' Document cleanup could not be confirmed.'; }
        throw new Error(`${error.message || 'Onboarding was rejected.'}${warning}`);
    }
    const row = Array.isArray(response.data) ? response.data[0] : response.data;
    if (!row || row.customer_id !== attempt.customerId || !row.account_id || !/^[0-9]{10}$/.test(row.account_number || '') || !row.account_status) {
        const uncertain = new Error(`Submission response was incomplete. Retry reference ${attempt.customerId} to confirm.`);
        uncertain.keepAttempt = true;
        throw uncertain;
    }
    return row;
}
