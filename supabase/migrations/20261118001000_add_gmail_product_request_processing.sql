create table public.gmail_product_requests (
  id uuid primary key default gen_random_uuid(),
  gmail_message_id text not null unique,
  status text not null check (status in ('processing', 'processed', 'needs_review', 'insufficient_stock')),
  reason text,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

create table public.gmail_product_request_lines (
  request_id uuid not null references public.gmail_product_requests(id) on delete cascade,
  line_number integer not null,
  requested_name text not null,
  requested_manufacturer text,
  requested_category text,
  requested_pieces numeric(12,3) not null,
  product_id uuid references public.products(id),
  deducted_pieces numeric(12,3) not null default 0,
  primary key (request_id, line_number)
);

alter table public.gmail_product_requests enable row level security;
alter table public.gmail_product_request_lines enable row level security;
grant all on public.gmail_product_requests, public.gmail_product_request_lines to service_role;

create or replace function public.process_gmail_product_request(
  p_gmail_message_id text,
  p_received_at timestamptz,
  p_items jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_existing_status text;
  v_item record;
  v_product_id uuid;
  v_match_count integer;
  v_line_no integer := 0;
  v_product record;
  v_lot record;
  v_remaining numeric(12,3);
  v_take numeric(12,3);
  v_ratio numeric(18,6);
  v_available numeric(14,3);
begin
  if coalesce(trim(p_gmail_message_id), '') = ''
     or coalesce(jsonb_typeof(p_items), '') <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Message id and at least one item are required';
  end if;

  insert into public.gmail_product_requests(gmail_message_id, status, received_at)
  values (p_gmail_message_id, 'processing', coalesce(p_received_at, now()))
  on conflict (gmail_message_id) do nothing
  returning id into v_request_id;
  if v_request_id is null then
    select r.status into v_existing_status
    from public.gmail_product_requests r where r.gmail_message_id = p_gmail_message_id;
    return jsonb_build_object('status', 'duplicate', 'existing_status', v_existing_status);
  end if;

  for v_item in
    select x.name, x.manufacturer, x.category, x.quantity
    from jsonb_to_recordset(p_items) as x(name text, manufacturer text, category text, quantity numeric)
  loop
    v_line_no := v_line_no + 1;
    if coalesce(trim(v_item.name), '') = '' or v_item.quantity is null
       or v_item.quantity <= 0 or v_item.quantity <> trunc(v_item.quantity) then
      insert into public.gmail_product_request_lines(
        request_id, line_number, requested_name, requested_manufacturer,
        requested_category, requested_pieces)
      values (v_request_id, v_line_no, coalesce(nullif(trim(v_item.name), ''), '[nome mancante]'),
              v_item.manufacturer, v_item.category, coalesce(v_item.quantity, 0));
      update public.gmail_product_requests
      set status = 'needs_review', reason = 'Nome prodotto o quantità in pezzi non valida'
      where id = v_request_id;
      return jsonb_build_object('status', 'needs_review', 'reason', 'Dati prodotto o quantità non validi');
    end if;

    select count(*) into v_match_count
    from public.products p join public.inventory_categories c on c.id = p.category_id
    where lower(btrim(p.name)) = lower(btrim(v_item.name))
      and (v_item.manufacturer is null or lower(btrim(p.manufacturer)) = lower(btrim(v_item.manufacturer)))
      and (v_item.category is null or lower(btrim(c.name)) = lower(btrim(v_item.category)));
    if v_match_count <> 1 then
      insert into public.gmail_product_request_lines(
        request_id, line_number, requested_name, requested_manufacturer,
        requested_category, requested_pieces)
      values (v_request_id, v_line_no, trim(v_item.name), v_item.manufacturer,
              v_item.category, v_item.quantity);
      update public.gmail_product_requests
      set status = 'needs_review',
          reason = case when v_match_count = 0 then 'Prodotto non trovato' else 'Prodotto non univoco' end
      where id = v_request_id;
      return jsonb_build_object('status', 'needs_review',
        'reason', case when v_match_count = 0 then 'Prodotto non trovato' else 'Prodotto non univoco' end);
    end if;

    select p.id into v_product_id
    from public.products p join public.inventory_categories c on c.id = p.category_id
    where lower(btrim(p.name)) = lower(btrim(v_item.name))
      and (v_item.manufacturer is null or lower(btrim(p.manufacturer)) = lower(btrim(v_item.manufacturer)))
      and (v_item.category is null or lower(btrim(c.name)) = lower(btrim(v_item.category)))
    limit 1;
    insert into public.gmail_product_request_lines(
      request_id, line_number, requested_name, requested_manufacturer,
      requested_category, requested_pieces, product_id)
    values (v_request_id, v_line_no, trim(v_item.name), v_item.manufacturer,
            v_item.category, v_item.quantity, v_product_id);
  end loop;

  for v_product in
    select l.product_id, sum(l.requested_pieces) as requested_pieces
    from public.gmail_product_request_lines l
    where l.request_id = v_request_id
    group by l.product_id order by l.product_id
  loop
    perform 1 from public.inventory_lots l
    where l.product_id = v_product.product_id
    order by l.expires_on asc nulls last, l.id for update;
    select coalesce(sum(l.piece_count), 0) into v_available
    from public.inventory_lots l where l.product_id = v_product.product_id;
    if v_available < v_product.requested_pieces then
      update public.gmail_product_requests
      set status = 'insufficient_stock', reason = 'Giacenza insufficiente'
      where id = v_request_id;
      return jsonb_build_object('status', 'insufficient_stock',
        'product_id', v_product.product_id, 'available_pieces', v_available,
        'requested_pieces', v_product.requested_pieces);
    end if;
  end loop;

  for v_item in
    select l.line_number, l.product_id, l.requested_pieces
    from public.gmail_product_request_lines l
    where l.request_id = v_request_id order by l.line_number
  loop
    v_remaining := v_item.requested_pieces;
    for v_lot in
      select l.id, l.piece_count, l.quantity
      from public.inventory_lots l
      where l.product_id = v_item.product_id and coalesce(l.piece_count, 0) > 0
      order by l.expires_on asc nulls last, l.id for update
    loop
      exit when v_remaining <= 0;
      v_take := least(v_remaining, v_lot.piece_count);
      v_ratio := case when v_lot.piece_count > 0 and v_lot.quantity is not null
                      then v_lot.quantity / v_lot.piece_count else 0 end;
      update public.inventory_lots
      set piece_count = piece_count - v_take,
          quantity = case when quantity is null then null
                          else greatest(0, quantity - v_take * v_ratio) end
      where id = v_lot.id;
      v_remaining := v_remaining - v_take;
    end loop;
    update public.gmail_product_request_lines
    set deducted_pieces = requested_pieces
    where request_id = v_request_id and line_number = v_item.line_number;
  end loop;

  update public.gmail_product_requests
  set status = 'processed', processed_at = now() where id = v_request_id;
  return jsonb_build_object('status', 'processed', 'request_id', v_request_id);
end;
$$;

revoke all on function public.process_gmail_product_request(text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.process_gmail_product_request(text, timestamptz, jsonb) to service_role;
