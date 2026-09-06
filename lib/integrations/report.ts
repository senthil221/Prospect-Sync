type Batch={status:string;emails:string[];dispatchEmails:string[]|null;outcome:{added?:string[];skipped?:{email:string;reason:string}[];reason?:string}|null};
export function deliveryReport(batches:Batch[]) {
  const cell=(value:string)=>`"${(/^[=+@\-\t\r]/.test(value)?"'":"")+value.replaceAll('"','""')}"`;
  const rows=[['email','outcome','reason']];
  for(const b of batches){
    const added=new Set(b.outcome?.added ?? []);
    const skipped=new Map((b.outcome?.skipped ?? []).map(s=>[s.email,s.reason]));
    for(const email of b.emails ?? []){
      let state=b.status==='needs_review'?'uncertain':b.status==='cancelled'?'cancelled':'not_confirmed';
      let reason=b.outcome?.reason ?? '';
      if(reason==='provider_rejected')state='rejected';
      if(added.has(email)){state='added';reason='';}
      else if(skipped.has(email)){state='skipped';reason=skipped.get(email) ?? '';}
      else if(b.dispatchEmails && !b.dispatchEmails.includes(email)){state='suppressed';reason='Suppressed or source removed before upload';}
      rows.push([email,state,reason]);
    }
  }
  return rows.map(row=>row.map(cell).join(',')).join('\r\n');
}
