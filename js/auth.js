// /js/auth.js
import { supabase } from './config.js';

document.addEventListener('DOMContentLoaded', () => {
    const loginForm = document.getElementById('login-form');
    const mfaForm = document.getElementById('mfa-form');
    const stage1 = document.getElementById('login-stage-1');
    const stage2 = document.getElementById('login-stage-2');

    // --- STAGE 1: Standard Email & Password Login ---
    if (loginForm) {
        loginForm.addEventListener('submit', async (e) => {
            e.preventDefault(); 
            
            const email = document.getElementById('email').value;
            const password = document.getElementById('password').value;
            const submitBtn = loginForm.querySelector('button');
            
            submitBtn.innerHTML = 'Authenticating...';
            submitBtn.disabled = true;

            const { data, error } = await supabase.auth.signInWithPassword({
                email: email,
                password: password,
            });

            if (error) {
                alert(`Authentication Failed: ${error.message}`);
                submitBtn.innerHTML = 'Authenticate <span class="material-symbols-outlined align-middle fs-6 ms-1">lock</span>';
                submitBtn.disabled = false;
                return;
            }

            const { data: mfaData } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
            
            if (mfaData.nextLevel === 'aal2' && mfaData.currentLevel === 'aal1') {
                stage1.classList.add('d-none');
                stage2.classList.remove('d-none');
            } else {
                // THE REDIRECT IS BACK ON
                routeUserSecurely();
            }
        }); // <-- THIS is what was missing!
    }

    // --- STAGE 2: MFA Code Verification ---
    if (mfaForm) {
        mfaForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            const code = document.getElementById('mfa-code').value;
            const submitBtn = mfaForm.querySelector('button');
            
            submitBtn.innerHTML = 'Verifying...';
            submitBtn.disabled = true;

            const { data: factors } = await supabase.auth.mfa.listFactors();
            const totpFactor = factors.totp[0];

            if (!totpFactor) {
                alert('No security factor found for this account.');
                submitBtn.innerHTML = 'Verify Identity';
                submitBtn.disabled = false;
                return;
            }

            const challenge = await supabase.auth.mfa.challenge({ factorId: totpFactor.id });
            
            const { error } = await supabase.auth.mfa.verify({
                factorId: totpFactor.id,
                challengeId: challenge.data.id,
                code: code
            });

            if (error) {
                alert('Invalid Code. Please try again.');
                document.getElementById('mfa-code').value = ''; 
                submitBtn.innerHTML = 'Verify Identity';
                submitBtn.disabled = false;
            } else {
                routeUserSecurely();
            }
        });
    }

    async function routeUserSecurely() {
        const { data: { session } } = await supabase.auth.getSession();
        if (!session) return;
        
        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role;
        
        if (userRole === 'it_admin') {
            window.location.href = 'admin-dashboard.html';
        } else {
            window.location.href = 'dashboard.html';
        }
    }
});