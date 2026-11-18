create extension if not exists pgcrypto;

create table public.inventory_categories (id uuid primary key default gen_random_uuid(), name text not null unique, sort_order integer not null default 0, created_at timestamptz not null default now());
create table public.products (id uuid primary key default gen_random_uuid(), name text not null, manufacturer text, category_id uuid not null references public.inventory_categories(id), format text, weight numeric(12,3), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique (category_id, name, manufacturer, format, weight));
create table public.inventory_lots (id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete cascade, lot_code text, expires_on date, piece_count numeric(12,3), quantity numeric(14,3), source_sheet text not null, source_row integer, imported_at timestamptz not null default now(), created_at timestamptz not null default now());
create index inventory_lots_product_id_idx on public.inventory_lots(product_id);
create index inventory_lots_expires_on_idx on public.inventory_lots(expires_on);
create index products_category_id_idx on public.products(category_id);
create view public.inventory_stock with (security_invoker = true) as select l.id as lot_id, p.id as product_id, p.name, p.manufacturer, c.name as category, p.format, p.weight, l.lot_code, l.expires_on, l.piece_count, l.quantity, (l.expires_on is not null and l.expires_on < current_date) as is_expired, l.source_sheet, l.source_row, l.imported_at from public.inventory_lots l join public.products p on p.id = l.product_id join public.inventory_categories c on c.id = p.category_id;
alter table public.inventory_categories enable row level security;
alter table public.products enable row level security;
alter table public.inventory_lots enable row level security;
grant select, insert, update, delete on public.inventory_categories, public.products, public.inventory_lots to authenticated;
grant all on public.inventory_categories, public.products, public.inventory_lots to service_role;
grant select on public.inventory_stock to authenticated, service_role;
