-- Phase 2 fiscal period administration.
-- Explicit period boundaries prevent silent posting into unconfigured accounting years.
create function public.create_fiscal_period(
  p_organization_id uuid,p_start date,p_end date
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not exists(
    select 1 from public.organization_members
    where organization_id=p_organization_id and user_id=auth.uid()
      and role in ('owner','administrator','accountant')
  ) then raise exception 'Not authorized to manage periods'; end if;
  if p_start is null or p_end is null or p_start>p_end or p_end-p_start>370
    then raise exception 'Invalid fiscal period bounds'; end if;
  perform 1 from public.organizations where id=p_organization_id for update;
  if exists(select 1 from public.fiscal_periods where organization_id=p_organization_id
    and start_date<=p_end and end_date>=p_start) then
    raise exception 'Fiscal periods must not overlap';
  end if;
  insert into public.fiscal_periods(organization_id,start_date,end_date)
  values(p_organization_id,p_start,p_end) returning id into v_id;
  return v_id;
end $$;
create function public.set_fiscal_period_lock(
  p_organization_id uuid,p_period_id uuid,p_locked boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null or not exists(
    select 1 from public.organization_members where organization_id=p_organization_id
      and user_id=auth.uid() and role in ('owner','administrator','accountant')
  ) then raise exception 'Not authorized to manage periods'; end if;
  if p_locked is null then raise exception 'Period lock state required'; end if;
  perform 1 from public.organizations where id=p_organization_id for update;
  update public.fiscal_periods set is_locked=p_locked
    where organization_id=p_organization_id and id=p_period_id;
  if not found then raise exception 'Fiscal period not found'; end if;
end $$;
revoke all on function public.create_fiscal_period(uuid,date,date) from public, anon;
grant execute on function public.create_fiscal_period(uuid,date,date) to authenticated;
revoke all on function public.set_fiscal_period_lock(uuid,uuid,boolean) from public, anon;
grant execute on function public.set_fiscal_period_lock(uuid,uuid,boolean) to authenticated;
