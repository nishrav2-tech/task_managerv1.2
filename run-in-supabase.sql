-- 1) Closing costs on every property (null = never entered, shown in red in the app)
alter table public.properties add column if not exists buy_closing_costs numeric;
alter table public.properties add column if not exists sell_closing_costs numeric;
-- 2) Calendar picker (from the earlier update)
alter table public.gcal_connections add column if not exists shown_calendars text[];
