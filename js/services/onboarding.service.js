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
    const prefix = `${tenantId}/${customerId}/`;
    const idPath = `${prefix}id_document.${documentExtension(input.idFile)}`;
    const utilityPath = `${prefix}utility_bill.${documentExtension(input.utilityFile)}`;
    const documents = { p_customer_id: customerId, p_id_path: idPath, p_utility_path: utilityPath };
    let rpc = 'onboard_customer';
    let payload;
    if (type === 'RETAIL') {
        const firstName = input.firstName?.trim();
        const lastName = input.lastName?.trim();
        const bvn = input.bvn?.trim();
        if (!firstName || !lastName || !/^[0-9]{11}$/.test(bvn || '')) {
            throw new Error('Enter the customer name and an 11-digit BVN.');
        }
        payload = { ...documents, p_customer_type: type, p_first_name: firstName,
            p_last_name: lastName, p_entity_name: null, p_bvn: bvn };
    } else if (type === 'CORPORATE') {
        const entityName = input.entityName?.trim();
        const registration = input.registrationNumber?.trim().toUpperCase().replace(/^RC[ -]*/, '').trim();
        const people = (input.people || []).map(person => Object.freeze({
            full_name: person.full_name.trim(), role: person.role, bvn: person.bvn.trim(),
            pep_declaration: person.pep_declaration
        }));
        if (!entityName || entityName.length > 200 || !/^[0-9]{1,20}$/.test(registration || '')) {
            throw new Error('Enter the registered company name and a valid CAC RC number.');
        }
        if (!people.length || people.length > 50 || people.some(person =>
            !person.full_name || person.full_name.length > 200 || !/^[0-9]{11}$/.test(person.bvn) ||
            !['DIRECTOR', 'SIGNATORY', 'BENEFICIAL_OWNER'].includes(person.role))) {
            throw new Error('Enter a name, role, and 11-digit BVN for each linked person.');
        }
        if (people.some(person => !['NO_EXPOSURE', 'EXPOSURE', 'UNKNOWN'].includes(person.pep_declaration))) {
            throw new Error('Record a PEP declaration for each linked person.');
        }
        rpc = 'onboard_corporate_customer';
        payload = { ...documents, p_entity_name: entityName, p_registration_number: registration,
            p_people: Object.freeze(people) };
    } else {
        throw new Error('Select a customer type.');
    }
    return { customerId, idFile: input.idFile, utilityFile: input.utilityFile,
        uploaded: new Set(), rpcStarted: false, rpc, payload: Object.freeze(payload) };
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
    try { response = await client.rpc(attempt.rpc, attempt.payload); }
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
