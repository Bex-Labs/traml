import {supabase} from './config.js';
import {beginAuthenticatorEnrollment, getMfaState, requiresComplianceMfa, verifyAuthenticator} from './services/compliance-mfa.js';

class SignInTimeout extends Error {}

async function waitForSignInStep(operation, label) {
    let timer;
    try {
        return await Promise.race([
            operation,
            new Promise((_, reject) => {
                timer = setTimeout(() => reject(new SignInTimeout(
                    `${label} timed out. Reload this page before trying again.`
                )), 15000);
            })
        ]);
    } finally {
        clearTimeout(timer);
    }
}

document.addEventListener('DOMContentLoaded', () => {
    const $ = id => document.getElementById(id);
    const login = $('login-form');
    const challenge = $('mfa-form');
    const status = $('login-status');
    const code = $('mfa-code');
    const start = $('mfa-start');
    const qr = $('mfa-qr');
    const factors = $('mfa-factor');
    let user;
    let enrollmentFactor;

    async function continueSignIn(signedInUser) {
        status.textContent = 'Checking authenticator status…';
        const assurance = await waitForSignInStep(getMfaState(supabase), 'Authenticator status check');
        const isEnrollment = assurance.nextLevel !== 'aal2' && requiresComplianceMfa(signedInUser);
        if (assurance.currentLevel === 'aal2' || (!isEnrollment && assurance.nextLevel !== 'aal2')) {
            route(signedInUser);
            return;
        }
        if (!isEnrollment) {
            status.textContent = 'Loading your authenticators…';
            const {data, error} = await waitForSignInStep(supabase.auth.mfa.listFactors(), 'Authenticator lookup');
            if (error) throw error;
            const verified = (data?.totp ?? []).filter(factor => factor.status === 'verified');
            if (!verified.length) throw Error('No verified authenticator is available. Contact your administrator.');
            factors.replaceChildren(...verified.map((factor, index) =>
                new Option(factor.friendly_name || `Authenticator ${index + 1}`, factor.id)));
            $('mfa-factor-picker').classList.toggle('hidden', verified.length < 2);
        }
        user = signedInUser;
        $('password').value = '';
        $('login-stage-1').classList.add('hidden');
        $('login-stage-2').classList.remove('hidden');
        challenge.classList.toggle('hidden', isEnrollment);
        start.classList.toggle('hidden', !isEnrollment);
        if (isEnrollment) {
            $('mfa-heading').textContent = 'Set up your authenticator';
            $('mfa-instructions').textContent = 'Connect an authenticator app to finish signing in.';
        }
        status.textContent = '';
        (isEnrollment ? start : code).focus();
    }

    login.addEventListener('submit', async event => {
        event.preventDefault();
        const button = login.querySelector('button');
        button.disabled = true;
        status.textContent = 'Checking your email and password…';
        let timedOut = false;
        try {
            const {data, error} = await waitForSignInStep(supabase.auth.signInWithPassword({
                email: $('email').value,
                password: $('password').value
            }), 'Password sign-in');
            if (error) throw error;
            await continueSignIn(data.user);
        } catch (error) {
            timedOut = error instanceof SignInTimeout;
            status.textContent = error.message || 'Sign-in could not be completed.';
        } finally {
            button.disabled = timedOut;
        }
    });

    start.addEventListener('click', async () => {
        start.disabled = true;
        try {
            const enrollment = await beginAuthenticatorEnrollment(supabase);
            enrollmentFactor = enrollment.factorId;
            qr.src = enrollment.qrImage;
            qr.classList.remove('hidden');
            start.classList.add('hidden');
            challenge.classList.remove('hidden');
            $('mfa-instructions').textContent = 'Scan the QR code with your authenticator app, then enter its six-digit code.';
            status.textContent = '';
            code.focus();
        } catch (error) {
            status.textContent = error.message || 'Could not start authenticator setup.';
        } finally {
            start.disabled = false;
        }
    });

    challenge.addEventListener('submit', async event => {
        event.preventDefault();
        if (!user) return;
        const button = challenge.querySelector('button');
        button.disabled = true;
        status.textContent = 'Verifying…';
        try {
            const factorId = enrollmentFactor || factors.value;
            if (!factorId) {
                status.textContent = 'Loading your authenticators…';
            const {data, error} = await waitForSignInStep(supabase.auth.mfa.listFactors(), 'Authenticator lookup');
                if (error) throw error;
                factorId = data?.totp?.find(item => item.status === 'verified')?.id;
            }
            if (!factorId) throw Error('No verified authenticator is available. Contact your administrator.');
            await verifyAuthenticator(supabase, factorId, code.value.trim());
            qr.removeAttribute('src');
            route(user, Boolean(enrollmentFactor));
        } catch (error) {
            status.textContent = error.message || 'Verification failed. Try again.';
            code.value = '';
            code.focus();
        } finally {
            button.disabled = false;
        }
    });

    if (new URLSearchParams(location.search).get('mfa') === 'resume') {
        const button = login.querySelector('button');
        button.disabled = true;
        let timedOut = false;
        status.textContent = 'Checking your sign-in session…';
        void waitForSignInStep(supabase.auth.getUser(), 'Session check').then(({data, error}) => {
            if (!error && data?.user) return continueSignIn(data.user);
            status.textContent = '';
        }).catch(error => {
            timedOut = error instanceof SignInTimeout;
            status.textContent = error.message || 'Sign in to continue.';
        }).finally(() => { button.disabled = timedOut; });
    }
});

function route(user, showSecurity) {
    const role = user?.app_metadata?.role;
    if (role === 'it_admin') location.replace('./admin-dashboard.html');
    else if (role === 'bank_manager') location.replace('./manager-dashboard.html');
    else if (['branch_manager','bankmanager','teller','sales_rep'].includes(role)) location.replace('./core-banking.html');
    else location.replace(showSecurity ? './dashboard.html?view=system-config&settings=security' : './dashboard.html');
}
