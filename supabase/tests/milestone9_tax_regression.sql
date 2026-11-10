begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999961','tax-preview-owner@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_result numeric;v_federal numeric;v_provincial numeric;v_failed boolean:=false;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999961',true);
 select sum(amount) into v_result from public.preview_canadian_indirect_taxes(
   'QC',current_date,100,'taxable',true);
 if v_result<>14.98 then raise exception 'QST + GST expected $14.98, got %',v_result;end if;
 select amount into v_federal from public.preview_canadian_indirect_taxes(
  'BC',current_date,100,'taxable',true) where component='GST';
 select amount into v_provincial from public.preview_canadian_indirect_taxes(
  'BC',current_date,100,'taxable',true) where component='PST';
 if v_federal<>5 or v_provincial<>7 then raise exception 'BC GST/PST estimate incorrect';end if;
 select sum(amount) into v_result from public.preview_canadian_indirect_taxes(
  'ON',current_date,100,'taxable',true);
 if v_result<>13 then raise exception 'ON HST estimate incorrect';end if;
 select sum(amount) into v_result from public.preview_canadian_indirect_taxes(
  'NS',current_date,100,'taxable',true);
 if v_result<>14 then raise exception '2026 Nova Scotia HST incorrect';end if;
 select sum(amount) into v_result from public.preview_canadian_indirect_taxes(
  'QC',current_date,100,'zero_rated',false);
 if v_result<>0 then raise exception 'Zero-rated GST/QST estimate incorrect';end if;
 select sum(amount) into v_result from public.preview_canadian_indirect_taxes(
  'SK',current_date,100,'taxable',true);
 if v_result<>11 then raise exception 'SK GST/PST estimate incorrect';end if;
 v_failed:=false;
 begin perform public.preview_canadian_indirect_taxes('QC',current_date,-100,'taxable',true);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Negative tax base accepted';end if;
 raise notice 'MILESTONE 9 CANADIAN TAX ESTIMATE REGRESSION PASSED';
end $qa$;
rollback;