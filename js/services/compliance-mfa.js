export function requiresComplianceMfa(user) {
    return ['compliance_officer', 'head_of_compliance'].includes(user?.app_metadata?.role);
}

export async function getMfaState(client) {
    const {data, error} = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) throw error;
    if (!data) throw Error('Authenticator status is unavailable.');
    return data;
}

export async function verifyAuthenticator(client, factorId, code) {
    if (!/^\d{6}$/.test(code)) throw Error('Enter the six-digit authenticator code.');
    const {error} = await client.auth.mfa.challengeAndVerify({factorId, code});
    if (error) throw error;
    if ((await getMfaState(client)).currentLevel !== 'aal2') {
        throw Error('Authenticator verification could not be confirmed.');
    }
}

export async function beginAuthenticatorEnrollment(client) {
    const friendlyName = `CoreAML authenticator ${crypto.randomUUID().slice(0, 8)}`;
    const {data, error} = await client.auth.mfa.enroll({factorType: 'totp', friendlyName});
    if (error) throw error;
    const qr = data?.totp?.qr_code;
    const prefix = 'data:image/svg+xml;utf-8,';
    if (!data?.id || typeof qr !== 'string' || !qr.startsWith(prefix)) {
        throw Error('Enrollment returned an invalid QR code.');
    }
    const svg = qr.slice(prefix.length);
    return {factorId: data.id, qrImage: svg.trimStart().startsWith('<') ? prefix + encodeURIComponent(svg) : qr};
}
