// Serializes saves and retains uncertain request IDs. No DOM or credentials.
export function createCaseDraftSession(service, draft, { onState = () => {}, submitReview = null, uuid = () => crypto.randomUUID() } = {}) {
    let revision = draft.revision, closed = draft.case_status === 'CLOSED', readOnly = draft.read_only;
    let desired = null, saved = draft.exists ? JSON.stringify({ narrative: draft.draft_narrative, snapshot: { entity_ids: draft.evidence_snapshot.entities.map(e => e.id), transaction_refs: [...draft.evidence_snapshot.txs] } }) : null;
    let pending = null, pendingClose = null, pendingSubmission = null, running = null, closing = false, submitting = false, submitted = false, conflict = false, error = '', disposed = false;
    function state(phase) { if (!disposed) onState({ phase, revision, readOnly: readOnly || closed || closing || conflict || !!pendingClose || submitting || submitted || !!pendingSubmission, closed, closing, conflict, submitting, submitted, uncertainSubmission: !!pendingSubmission, dirty: !!pending || (!!desired && JSON.stringify(desired) !== saved), uncertainClose: !!pendingClose, error }); }
    function ensureEditable() { if (disposed || readOnly || closed || submitted || conflict) throw new Error(conflict ? 'Draft changed elsewhere. Copy your text before reopening the case.' : 'Case is unavailable for editing.'); }
    function operation(action, payload) { return { alertId: draft.alert_id, caseReference: draft.case_reference, revision, requestId: uuid(), action, ...(payload ? { payload } : {}) }; }
    function failed(e) {
        error = e.message || 'Case request failed.';
        if (/revision conflict|membership or state changed/i.test(error)) conflict = true;
        if (e.definitive) pending = null;
        state(conflict ? 'conflict' : 'error');
    }
    async function drain() {
        while (pending || (desired && JSON.stringify(desired) !== saved)) {
            ensureEditable();
            if (!pending) pending = operation('SAVE', structuredClone(desired));
            state('saving');
            const ack = await service.act(pending);
            revision = ack.revision; saved = JSON.stringify(pending.payload); pending = null; error = '';
        }
        state('saved');
    }
    function flush() {
        if (!running) {
            running = drain().catch(e => { failed(e); throw e; }).finally(() => { running = null; });
        }
        return running.then(() => { if (pending || (desired && JSON.stringify(desired) !== saved)) return flush(); });
    }
    return {
        get editable() { return !disposed && !readOnly && !closed && !conflict && !closing && !pendingClose && !submitting && !pendingSubmission && !submitted; },
        get closing() { return closing; },
        get busy() { return closing || submitting || !!running; },
        get needsSave() { return !!pending || (!!desired && JSON.stringify(desired) !== saved); },
        get uncertainClose() { return !!pendingClose; },
        get uncertainSubmission() { return !!pendingSubmission; },
        get submitting() { return submitting; },
        get submissionKind() { return pendingSubmission?.kind; },
        save(payload) {
            try { ensureEditable(); if (submitting || pendingSubmission) throw new Error('Confirm the review submission before editing.'); if (closing || pendingClose) throw new Error('Closure is awaiting confirmation. Retry closure before editing.'); desired = structuredClone(payload); return flush(); }
            catch (e) { return Promise.reject(e); }
        },
        async close(payload) {
            if (submitting || pendingSubmission) throw new Error('Confirm the review submission before closing.');
            if (closing) throw new Error('Closure is already in progress.');
            ensureEditable(); closing = true; state('closing');
            try {
                if (!pendingClose) {
                    desired = structuredClone(payload); await flush();
                    pendingClose = operation('CLOSE');
                }
                state('closing');
                const ack = await service.act(pendingClose);
                revision = ack.revision; pendingClose = null; closed = true; error = ''; state('closed'); return ack;
            } catch (e) {
                error = e.message || 'Closure confirmation failed.';
                if (/revision conflict|membership or state changed/i.test(error)) conflict = true;
                if (e.definitive) pendingClose = null;
                throw e;
            } finally { closing = false; state(closed ? 'closed' : conflict ? 'conflict' : 'error'); }
        },
        async submit(kind,payload,dismissalReason=null) {
            if (submitting) throw new Error('Submission is already in progress.');
            ensureEditable();
            if (closing || pendingClose) throw new Error('Confirm closure before requesting a review.');
            if (!['QA','EXECUTIVE','REPORT'].includes(kind) || typeof submitReview !== 'function') throw new Error('Review submission is unavailable.');
            if (pendingSubmission && kind !== pendingSubmission.kind) throw new Error('Retry the original review type before choosing another outcome.');
            submitting=true;error='';state('submitting');
            try {
                if (!pendingSubmission) {
                    desired=structuredClone(payload);await flush();ensureEditable();
                    pendingSubmission={alertId:draft.alert_id,caseReference:draft.case_reference,revision,requestId:uuid(),kind,actorId:draft.owner_id||draft.investigator_id,tenantId:draft.tenant_id,alertIds:[...draft.alert_ids],...(kind==='QA'?{dismissalReason:structuredClone(dismissalReason)}:{})};
                }
                state('submitting');const ack=await submitReview(pendingSubmission);
                revision=ack.revision;submitted=true;pendingSubmission=null;error='';return ack;
            }catch(e){error=e.message||'Submission was not confirmed.';if(e.code==='40001')conflict=true;if(e.definitive)pendingSubmission=null;throw e;}
            finally{submitting=false;state(submitted?'submitted':'error');}
        },
        dispose() { disposed = true; },
        get draft() { return { ...draft, revision }; }
    };
}
