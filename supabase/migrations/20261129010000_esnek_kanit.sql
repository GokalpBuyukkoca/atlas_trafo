-- =====================================================================
-- Esnek mesaide eksik giriş: kanıt saati doğrudan yazılır
--
-- Gece işinin kanıtla düzeltme adımı (gece_isi_kanitla_duzelt) girişte
-- "kanıt + yürüme payı vardiya başından önceyse giriş = vardiya başı,
-- sonraysa amire sor" kuralını uygular. Esnek mesaide vardiya başı yoktur;
-- çalışan 09:40'ta da gelebilir. Bu yüzden esnek vardiyada:
--   * giriş kanıtı (kapı, yoksa servis) varsa giriş = kanıt + yürüme payı
--     olarak yazılır; amire "kanıt vardiya başından sonra" sorusu açılmaz.
--   * kanıt + yürüme payı PDKS çıkışından sonraya düşüyorsa yazılmaz
--     (tutarsız kayıt); gün eskisi gibi amire sorulur.
-- Esnek olmayan vardiyalarda ve çıkışta kural değişmedi.
-- =====================================================================

create or replace function pdks.gece_isi_kanitla_duzelt(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_yurume  interval := make_interval(mins => pdks.ayar_al('yurume_payi_dk'));
    v_say     integer := 0;
    v_ariza   bigint;
    v_esnek   boolean;
    v_giris   timestamptz;
    g         record;
    k         record;
begin
    for g in
        select * from pdks.gun_kaydi
        where is_gunu = p_gun and durum = 'eksik' and not pdks.donem_kilitli_mi(p_gun)
        order by id
    loop
        select coalesce(t.esnek, false) into v_esnek from pdks.vardiya_tanim t where t.id = g.vardiya_id;

        if g.giris_zamani is null then
            select * into k from pdks.gun_kaniti(g.id, 'giris');
            v_giris := null;
            if k.p_kanit_id is not null then
                if v_esnek then
                    -- Esnek: kanıttaki saat + yürüme payı (çıkıştan sonraya düşmüyorsa)
                    if g.cikis_zamani is null or k.p_zaman + v_yurume < g.cikis_zamani then
                        v_giris := k.p_zaman + v_yurume;
                    end if;
                elsif k.p_zaman + v_yurume <= g.planli_baslangic then
                    v_giris := g.planli_baslangic;
                end if;
            end if;

            if v_giris is not null then
                select a.id into v_ariza from pdks.ariza a
                where a.okuyucu_id = pdks.calisan_pdks_okuyucusu(g.calisan_id, p_gun)
                  and a.durum <> 'reddedildi' and k.p_zaman between a.baslangic and coalesce(a.bitis, 'infinity')
                limit 1;
                perform pdks.duzeltme_uygula(g.id, 'giris_zamani', v_giris::text,
                    case when v_esnek
                         then format('Esnek mesai: %s kaydı %s + yürüme payı; giriş %s olarak yazıldı',
                                     case k.p_kaynak when 'kapi' then 'Kapı' else 'Servis' end,
                                     to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI'),
                                     to_char(v_giris at time zone 'Europe/Istanbul', 'HH24:MI'))
                         else format('%s kaydı %s, vardiya başından önce; giriş vardiya başı olarak yazıldı',
                                     case k.p_kaynak when 'kapi' then 'Kapı' else 'Servis' end,
                                     to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI')) end,
                    'gece_isi', p_kanit_kaydi_id => k.p_kanit_id, p_ariza_id => v_ariza);
                v_say := v_say + 1;
                g.giris_zamani := v_giris;
            end if;
        end if;

        if g.cikis_zamani is null then
            select * into k from pdks.gun_kaniti(g.id, 'cikis', coalesce(g.giris_zamani, g.planli_baslangic));
            if k.p_kanit_id is not null then
                select a.id into v_ariza from pdks.ariza a
                where a.okuyucu_id = pdks.calisan_pdks_okuyucusu(g.calisan_id, p_gun)
                  and a.durum <> 'reddedildi' and k.p_zaman between a.baslangic and coalesce(a.bitis, 'infinity')
                limit 1;
                perform pdks.duzeltme_uygula(g.id, 'cikis_zamani', k.p_zaman::text,
                    format('%s kaydı %s; çıkış kanıttaki saat olarak yazıldı',
                           case k.p_kaynak when 'kapi' then 'Kapı' else 'Servis' end, to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI')),
                    'gece_isi', p_kanit_kaydi_id => k.p_kanit_id, p_ariza_id => v_ariza);
                v_say := v_say + 1;
            end if;
        end if;
    end loop;
    return v_say;
end;
$$;

revoke execute on function pdks.gece_isi_kanitla_duzelt(date) from public, anon, authenticated;
