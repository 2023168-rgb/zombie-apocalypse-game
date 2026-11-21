-- 좀비 아포칼립스 거래 시스템
create table if not exists public.player_trades (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','active','completed','rejected','cancelled')),
  sender_offer jsonb not null default '[]'::jsonb,
  recipient_offer jsonb not null default '[]'::jsonb,
  sender_ready boolean not null default false,
  recipient_ready boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create index if not exists player_trades_participants_idx on public.player_trades(sender_id,recipient_id,status);
alter table public.player_trades enable row level security;
drop policy if exists player_trades_read_participant on public.player_trades;
create policy player_trades_read_participant on public.player_trades for select to authenticated using (auth.uid()=sender_id or auth.uid()=recipient_id);
grant select on public.player_trades to authenticated;

create or replace function public.trade_request(p_recipient uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.uid() is null or p_recipient is null or p_recipient=auth.uid() then raise exception '잘못된 거래 대상이야.'; end if;
 if not exists(select 1 from public.profiles where id=p_recipient) then raise exception '플레이어를 찾을 수 없어.'; end if;
 if exists(select 1 from public.player_trades where status in ('pending','active') and (sender_id in (auth.uid(),p_recipient) or recipient_id in (auth.uid(),p_recipient))) then
   raise exception '이미 한 명의 플레이어가 거래 중입니다.';
 end if;
 insert into public.player_trades(sender_id,recipient_id) values(auth.uid(),p_recipient) returning id into v_id;
 return v_id;
end $$;

create or replace function public.trade_respond(p_trade_id uuid,p_accept boolean)
returns void language plpgsql security definer set search_path=public as $$
declare t public.player_trades%rowtype;
begin
 select * into t from public.player_trades where id=p_trade_id for update;
 if not found or t.recipient_id<>auth.uid() or t.status<>'pending' then raise exception '거래 요청이 만료됐어.'; end if;
 if p_accept and exists(select 1 from public.player_trades where id<>t.id and status in ('pending','active') and (sender_id in (t.sender_id,t.recipient_id) or recipient_id in (t.sender_id,t.recipient_id))) then raise exception '이미 한 명의 플레이어가 거래 중입니다.'; end if;
 update public.player_trades set status=case when p_accept then 'active' else 'rejected' end,updated_at=now() where id=t.id;
end $$;

create or replace function public.trade_set_offer(p_trade_id uuid,p_offer jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare t public.player_trades%rowtype; v_save jsonb; v_item jsonb; v_type text; v_id text; v_found boolean;
begin
 if jsonb_typeof(p_offer)<>'array' or jsonb_array_length(p_offer)>12 then raise exception '거래 아이템은 최대 12개까지 올릴 수 있어.'; end if;
 select * into t from public.player_trades where id=p_trade_id for update;
 if not found or t.status<>'active' or auth.uid() not in (t.sender_id,t.recipient_id) then raise exception '진행 중인 거래가 아니야.'; end if;
 select save_data into v_save from public.game_saves where user_id=auth.uid() and save_slot='main' for update;
 if v_save is null then raise exception '게임 저장 데이터를 찾을 수 없어.'; end if;
 for v_item in select value from jsonb_array_elements(p_offer) loop
   v_type:=v_item->>'type'; v_id:=v_item->>'id'; v_found:=false;
   if v_type='weapon' then
     select exists(select 1 from jsonb_array_elements(coalesce(v_save->'inventory','[]'::jsonb)) x where x->>'id'=v_id) into v_found;
     if v_found and (v_save->>'equipped')=v_id then raise exception '장착 중인 무기는 거래할 수 없어.'; end if;
   elsif v_type='armor' then
     select exists(select 1 from jsonb_array_elements(coalesce(v_save->'armorInventory','[]'::jsonb)) x where x->>'id'=v_id) into v_found;
     if v_found and exists(select 1 from jsonb_array_elements(coalesce(v_save->'armorInventory','[]'::jsonb)) x where x->>'id'=v_id and coalesce(v_save->'equippedArmor','{}'::jsonb)->>case x->>'slot' when 'helmet' then 'helmet' when 'vest' then 'vest' when 'gloves' then 'gloves' else 'none' end=x->>'name') then raise exception '장착 중인 방어구는 거래할 수 없어.'; end if;
   elsif v_type='job' then
     select exists(select 1 from jsonb_array_elements(coalesce(v_save->'jobInventory','[]'::jsonb)) x where x->>'id'=v_id) into v_found;
     if v_found and (v_save->>'equippedJob')=v_id then raise exception '장착 중인 직업은 거래할 수 없어.'; end if;
   else raise exception '거래할 수 없는 아이템 종류야.'; end if;
   if not v_found then raise exception '보유하지 않은 아이템이 포함돼 있어.'; end if;
 end loop;
 if auth.uid()=t.sender_id then update public.player_trades set sender_offer=p_offer,sender_ready=false,updated_at=now() where id=t.id;
 else update public.player_trades set recipient_offer=p_offer,recipient_ready=false,updated_at=now() where id=t.id; end if;
end $$;

create or replace function public.trade_set_ready(p_trade_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.player_trades%rowtype;
begin
 select * into t from public.player_trades where id=p_trade_id for update;
 if not found or t.status<>'active' or auth.uid() not in (t.sender_id,t.recipient_id) then raise exception '진행 중인 거래가 아니야.'; end if;
 if auth.uid()=t.sender_id then update public.player_trades set sender_ready=true,updated_at=now() where id=t.id;
 else update public.player_trades set recipient_ready=true,updated_at=now() where id=t.id; end if;
end $$;

create or replace function public.trade_finalize(p_trade_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.player_trades%rowtype; a jsonb; b jsonb; ao jsonb; bo jsonb; x jsonb; typ text; ident text; arr jsonb; moved jsonb; new_id bigint; i int;
begin
 select * into t from public.player_trades where id=p_trade_id for update;
 if not found or t.status<>'active' or auth.uid() not in (t.sender_id,t.recipient_id) or not t.sender_ready or not t.recipient_ready then raise exception '양쪽 플레이어가 모두 확정해야 해.'; end if;
 select save_data into a from public.game_saves where user_id=t.sender_id and save_slot='main' for update;
 select save_data into b from public.game_saves where user_id=t.recipient_id and save_slot='main' for update;
 if a is null or b is null then raise exception '한쪽의 게임 저장 데이터를 찾을 수 없어.'; end if;
 ao:=t.sender_offer; bo:=t.recipient_offer;
 for i in 1..2 loop
   if i=1 then x:=ao; else x:=bo; end if;
   for moved in select value from jsonb_array_elements(x) loop
     typ:=moved->>'type'; ident:=moved->>'id';
     if i=1 then arr:=a->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end;
     else arr:=b->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end; end if;
     if not exists(select 1 from jsonb_array_elements(coalesce(arr,'[]'::jsonb)) z where z->>'id'=ident) then raise exception '거래 아이템이 변경됐어. 거래를 다시 시작해줘.'; end if;
   end loop;
 end loop;
 -- sender items -> recipient, then recipient items -> sender
 for i in 1..2 loop
   x:=case when i=1 then ao else bo end;
   for moved in select value from jsonb_array_elements(x) loop
     typ:=moved->>'type'; ident:=moved->>'id';
     if i=1 then
       arr:=coalesce(a->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end,'[]'::jsonb);
       select value into moved from jsonb_array_elements(arr) where value->>'id'=ident;
       arr:=(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(arr) where value->>'id'<>ident);
       a:=jsonb_set(a,array[case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end],arr,true);
       if typ='weapon' and a->>'equipped'=ident then a:=jsonb_set(a,'{equipped}',to_jsonb(coalesce((arr->0->>'id')::bigint,0)),true); end if;
       if typ='job' and a->>'equippedJob'=ident then a:=jsonb_set(a,'{equippedJob}','null'::jsonb,true); end if;
       arr:=coalesce(b->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end,'[]'::jsonb);
       select coalesce(max((z->>'id')::bigint),0)+1 into new_id from jsonb_array_elements(arr) z;
       moved:=jsonb_set(moved,'{id}',to_jsonb(new_id),true);
       b:=jsonb_set(b,array[case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end],arr||jsonb_build_array(moved),true);
     else
       arr:=coalesce(b->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end,'[]'::jsonb);
       select value into moved from jsonb_array_elements(arr) where value->>'id'=ident;
       arr:=(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(arr) where value->>'id'<>ident);
       b:=jsonb_set(b,array[case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end],arr,true);
       if typ='weapon' and b->>'equipped'=ident then b:=jsonb_set(b,'{equipped}',to_jsonb(coalesce((arr->0->>'id')::bigint,0)),true); end if;
       if typ='job' and b->>'equippedJob'=ident then b:=jsonb_set(b,'{equippedJob}','null'::jsonb,true); end if;
       arr:=coalesce(a->case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end,'[]'::jsonb);
       select coalesce(max((z->>'id')::bigint),0)+1 into new_id from jsonb_array_elements(arr) z;
       moved:=jsonb_set(moved,'{id}',to_jsonb(new_id),true);
       a:=jsonb_set(a,array[case typ when 'weapon' then 'inventory' when 'armor' then 'armorInventory' else 'jobInventory' end],arr||jsonb_build_array(moved),true);
     end if;
   end loop;
 end loop;
 update public.game_saves set save_data=a,updated_at=now() where user_id=t.sender_id and save_slot='main';
 update public.game_saves set save_data=b,updated_at=now() where user_id=t.recipient_id and save_slot='main';
 update public.player_trades set status='completed',updated_at=now() where id=t.id;
end $$;

revoke all on function public.trade_request(uuid) from public;
revoke all on function public.trade_respond(uuid,boolean) from public;
revoke all on function public.trade_set_offer(uuid,jsonb) from public;
revoke all on function public.trade_set_ready(uuid) from public;
revoke all on function public.trade_finalize(uuid) from public;
grant execute on function public.trade_request(uuid) to authenticated;
grant execute on function public.trade_respond(uuid,boolean) to authenticated;
grant execute on function public.trade_set_offer(uuid,jsonb) to authenticated;
grant execute on function public.trade_set_ready(uuid) to authenticated;
grant execute on function public.trade_finalize(uuid) to authenticated;
