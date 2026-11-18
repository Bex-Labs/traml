import {beginAuthenticatorEnrollment, verifyAuthenticator} from '../services/compliance-mfa.js';
import {mountRuleGovernance} from './rule-governance.page.js';

export function mountAccountSettings(client, context) {
    const $ = id => document.getElementById(id);
    const {user,role,tenantId} = context;
    const name = $('settings-display-name');
    const photo = $('settings-photo-file');
    const profileStatus = $('settings-profile-status');
    const photoStatus = $('settings-photo-status');
    const remove = $('settings-photo-remove');
    const profilePhoto = $('settings-photo-preview');
    const avatar = $('ui-user-avatar');
    const fallback = $('ui-user-avatar-fallback');
    const bucket = client.storage.from('staff-profile-photos');
    const formats = new Set(['image/jpeg','image/png','image/webp']);
    let objectUrl;

    function showName(value) {
        name.value = String(value ?? '').slice(0,100);
        $('ui-user-name').textContent = name.value || user.email;
    }
    function showPhoto(blob) {
        if (objectUrl) URL.revokeObjectURL(objectUrl);
        objectUrl = blob ? URL.createObjectURL(blob) : undefined;
        for (const image of [avatar,profilePhoto]) {
            if (objectUrl) image.src = objectUrl;
            else image.removeAttribute('src');
            image.classList.toggle('d-none', !objectUrl);
        }
        fallback.classList.toggle('d-none', Boolean(objectUrl));
        $('settings-photo-placeholder').hidden = Boolean(objectUrl);
        remove.disabled = !objectUrl;
    }

    showName(user.user_metadata?.display_name || user.user_metadata?.full_name);
    $('settings-email').textContent = user.email;
    $('settings-role').textContent = role.replaceAll('_',' ');
    $('settings-bank').textContent = tenantId;
    const settings = $('view-system-config');
    const tabs = [...settings.querySelectorAll('[data-settings-section]')];
    const institution = tabs.find(tab => tab.dataset.settingsSection === 'institution');
    institution.hidden = role !== 'head_of_compliance';
    let loadRules;
    function showSection(section) {
        for (const tab of tabs) {
            const key = tab.dataset.settingsSection;
            const selected = section === key;
            tab.setAttribute('aria-pressed', String(selected));
            $(`settings-panel-${key}`).hidden = !selected;
        }
        if (section === 'rules') {
            loadRules ??= mountRuleGovernance($('settings-panel-rules'), client);
            void loadRules();
        }
    }
    for (const tab of tabs) tab.addEventListener('click', () => showSection(tab.dataset.settingsSection));
    const requestedSection = new URLSearchParams(location.search).get('settings');
    const requested = ['profile', 'security'].includes(requestedSection) ? 'account' : requestedSection;
    if (tabs.some(tab => tab.dataset.settingsSection === requested && !tab.hidden)) showSection(requested);

    $('settings-profile-form').addEventListener('submit', async event => {
        event.preventDefault();
        const button = event.currentTarget.querySelector('button');
        button.disabled = true;
        const displayName = name.value.trim();
        try {
            if (displayName.length < 2 || displayName.length > 100) throw Error('Enter a name of 2–100 characters.');
            const {data,error} = await client.auth.updateUser({data:{display_name:displayName}});
            if (error) throw error;
            showName(data.user.user_metadata.display_name);
            profileStatus.textContent = 'Display name saved.';
        } catch (error) {
            profileStatus.textContent = error.message || 'Could not save your name.';
        } finally {
            button.disabled = false;
        }
    });

    const photoForm = $('settings-photo-form');
    const upload = $('settings-photo-upload');
    async function refreshPhoto() {
        const {data,error} = await bucket.list('',{search:user.id,limit:1});
        if (error) throw error;
        if (!data.some(item => item.name === user.id)) return showPhoto(null);
        const {data:blob,error:downloadError} = await bucket.download(user.id);
        if (downloadError) throw downloadError;
        if (!formats.has(blob.type)) throw Error('The stored photo is not a supported image.');
        showPhoto(blob);
    }
    async function changePhoto(action) {
        upload.disabled = remove.disabled = true;
        try {
            await action();
        } catch (error) {
            photoStatus.textContent = error.message || 'Could not update your photo.';
        } finally {
            upload.disabled = false;
            remove.disabled = !objectUrl;
        }
    }
    photoForm.addEventListener('submit', event => {
        event.preventDefault();
        const file = photo.files[0];
        void changePhoto(async () => {
            if (!file || !formats.has(file.type) || file.size > 2 * 1024 * 1024) {
                throw Error('Choose a JPEG, PNG or WebP photo up to 2 MB.');
            }
            const {error} = await bucket.upload(user.id,file,{upsert:true,contentType:file.type});
            if (error) throw error;
            showPhoto(file);
            photoForm.reset();
            photoStatus.textContent = 'Profile photo saved.';
        });
    });
    remove.addEventListener('click', () => void changePhoto(async () => {
        const {error} = await bucket.remove([user.id]);
        if (error) throw error;
        showPhoto(null);
        photoStatus.textContent = 'Profile photo removed.';
    }));
    void refreshPhoto().catch(error => { photoStatus.textContent = error.message; })
        .finally(() => { upload.disabled = false; });
    const mfaStatus = $('settings-mfa-status');
    const start = $('settings-mfa-start');
    const enrollmentPanel = $('settings-mfa-enroll');
    const qr = $('settings-mfa-qr');
    const code = $('settings-mfa-code');
    let factorId;

    async function authenticatorIsSetUp() {
        const {data, error} = await client.auth.mfa.listFactors();
        if (error) throw error;
        const isSetUp = data.totp.some(factor => factor.status === 'verified');
        start.hidden = isSetUp;
        mfaStatus.textContent = isSetUp ? 'Authenticator already set up.' : 'Authenticator setup required.';
        return isSetUp;
    }

    void authenticatorIsSetUp().catch(() => {
        mfaStatus.textContent = 'Authenticator status unavailable. Reload the page to try again.';
    });

    start.addEventListener('click', async () => {
        start.disabled = true;
        try {
            if (await authenticatorIsSetUp()) return;
            const enrollment = await beginAuthenticatorEnrollment(client);
            factorId = enrollment.factorId;
            qr.src = enrollment.qrImage;
            enrollmentPanel.hidden = false;
            start.hidden = true;
            code.focus();
        } catch (error) {
            mfaStatus.textContent = error.message || 'Could not start authenticator setup.';
        } finally {
            start.disabled = false;
        }
    });

    $('settings-mfa-form').addEventListener('submit', async event => {
        event.preventDefault();
        if (!factorId) return;
        const form = event.currentTarget;
        const button = form.querySelector('button');
        button.disabled = true;
        try {
            await verifyAuthenticator(client, factorId, code.value.trim());
            factorId = undefined;
            qr.removeAttribute('src');
            form.reset();
            enrollmentPanel.hidden = true;
            mfaStatus.textContent = 'Authenticator already set up.';
        } catch (error) {
            mfaStatus.textContent = error.message || 'Verification failed. Try again.';
            code.value = '';
            code.focus();
        } finally {
            button.disabled = false;
        }
    });

    $('settings-password-form').addEventListener('submit', async event => {
        event.preventDefault();
        const form = event.currentTarget;
        const button = form.querySelector('button');
        const status = $('settings-password-status');
        const password = $('settings-password').value;
        if (password !== $('settings-password-confirm').value) {
            status.textContent = 'The passwords do not match.';
            $('settings-password-confirm').focus();
            return;
        }
        button.disabled = true;
        status.textContent = 'Changing password…';
        try {
            const {error} = await client.auth.updateUser({password});
            if (error) throw error;
            form.reset();
            status.textContent = 'Password changed.';
        } catch (error) {
            status.textContent = error.message || 'Could not change your password.';
        } finally {
            button.disabled = false;
        }
    });
}
