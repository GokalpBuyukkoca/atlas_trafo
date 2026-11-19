-- =====================================================================
-- Bölge yetkisi izi
--   Bölge yetkisi verilince ve kaldırılınca kim / ne zaman bilgisi silinmeyen
--   bolge_yetkisi_gecmisi tablosuna yazılır. Yazma işini trigger yapar; böylece
--   örnek veri gibi doğrudan eklenen yetkiler de iz bırakır. Kaldıran kişiyi
--   bolge_yetkisi_kaldir() fonksiyonu işlem değişkeniyle bildirir.
-- =====================================================================

create table pdks.bolge_yetkisi_gecmisi (
    id            bigint generated always as identity primary key,
    bolge_id      smallint not null references pdks.bolge (id),
    departman_id  smallint not null references pdks.departman (id),
    islem         text not null check (islem in ('verildi', 'kaldirildi')),
    yapan_id      bigint references pdks.kullanici (id),
    zaman         timestamptz not null default now()
);
create index bolge_yetkisi_gecmisi_bolge on pdks.bolge_yetkisi_gecmisi (bolge_id, departman_id, id);
comment on table pdks.bolge_yetkisi_gecmisi is
    'Bölge yetkisinin verilme / kaldırılma izi (kim, ne zaman). Silinmez, değiştirilmez.';

create trigger bolge_yetkisi_gecmisi_degistirilemez before update or delete on pdks.bolge_yetkisi_gecmisi
    for each row execute function pdks.degistirilemez();
create trigger bolge_yetkisi_gecmisi_bosaltilamaz before truncate on pdks.bolge_yetkisi_gecmisi
    for each statement execute function pdks.degistirilemez();

create function pdks.bolge_yetkisi_iz()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_op = 'INSERT' then
        insert into pdks.bolge_yetkisi_gecmisi (bolge_id, departman_id, islem, yapan_id, zaman)
        values (new.bolge_id, new.departman_id, 'verildi', new.veren_id, new.verilis_zamani);
        return new;
    end if;
    insert into pdks.bolge_yetkisi_gecmisi (bolge_id, departman_id, islem, yapan_id)
    values (old.bolge_id, old.departman_id, 'kaldirildi',
            nullif(current_setting('pdks.islem_yapan', true), '')::bigint);
    return old;
end;
$$;
create trigger bolge_yetkisi_iz after insert or delete on pdks.bolge_yetkisi
    for each row execute function pdks.bolge_yetkisi_iz();
create trigger bolge_yetkisi_bosaltilamaz before truncate on pdks.bolge_yetkisi
    for each statement execute function pdks.degistirilemez();

-- Bu migration'dan önce verilmiş yetkiler için "verildi" izi
insert into pdks.bolge_yetkisi_gecmisi (bolge_id, departman_id, islem, yapan_id, zaman)
select bolge_id, departman_id, 'verildi', veren_id, verilis_zamani from pdks.bolge_yetkisi
order by verilis_zamani;

-- Kaldıran kişi ize yazılır
create or replace function pdks.bolge_yetkisi_kaldir(p_bolge_id smallint, p_departman_id smallint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('isg');
begin
    perform set_config('pdks.islem_yapan', v_ben::text, true);
    delete from pdks.bolge_yetkisi where bolge_id = p_bolge_id and departman_id = p_departman_id;
    if not found then
        raise exception 'Bu departmanın bu bölgede yetkisi yok.';
    end if;
    perform set_config('pdks.islem_yapan', '', true);
end;
$$;

alter table pdks.bolge_yetkisi_gecmisi enable row level security;
create policy ik_yonetici_okur on pdks.bolge_yetkisi_gecmisi for select to authenticated using (pdks.tum_veriyi_gorur());
create policy isg_okur   on pdks.bolge_yetkisi_gecmisi for select to authenticated using (pdks.oturum_rolu() = 'isg');
create policy admin_okur on pdks.bolge_yetkisi_gecmisi for select to authenticated using (pdks.oturum_rolu() = 'admin');
grant select on pdks.bolge_yetkisi_gecmisi to authenticated;

revoke execute on function pdks.bolge_yetkisi_iz() from public, anon, authenticated;
