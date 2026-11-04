// A manual attestation is not a successful external identity or sanctions API call.
export function createKycReview(input) {
 const text=(v,min,max,label)=>{v=String(v||'').trim();if(v.length<min||v.length>max)throw new Error(`${label} must contain ${min}–${max} characters.`);return v;};
 if(!input.customerId)throw new Error('Select an application first.');
 if(!input.identityChecked||!input.addressChecked||!input.screeningChecked)throw new Error('Confirm identity, address and screening review before approval.');
 const flags={face_to_face:!!input.faceToFace,cash_intensive:!!input.cashIntensive,complex_structure:!!input.complexStructure,pep_or_adverse_media:!!input.pepOrAdverseMedia};
 return Object.freeze({p_review_id:crypto.randomUUID(),p_customer_id:input.customerId,
  p_identity_reference:text(input.identityReference,5,500,'Identity evidence reference'),
  p_screening_reference:text(input.screeningReference,5,500,'Screening evidence reference'),
  p_notes:text(input.notes,20,4000,'Review notes'),p_flags:Object.freeze(flags)});
}
export async function submitKycReview(client,payload){
 const {data,error}=await client.rpc('approve_manual_kyc',payload);
 if(error){const failure=new Error(error.message||'Approval failed.');
  failure.definiteRejection=['22023','23514','23505','42501'].includes(error.code);throw failure;}
 const row=data?.[0];
 if(row?.customer_id!==payload.p_customer_id||row?.review_id!==payload.p_review_id||!row.account_id||row.account_status!=='ACTIVE')
  throw new Error('Approval response is incomplete. Retry the same review to confirm its outcome.');
 return row;
}
