CREATE OR REPLACE FUNCTION api.cov(x double precision, y double precision)
 RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
 LANGUAGE plpgsql
AS $function$
BEGIN
   return query
   SELECT
          coalesce(vn.visible_name, cov_mno.operator)::VARCHAR as operator,
          public.cov_mno.reference::VARCHAR,
          public.cov_mno.license::VARCHAR,
          public.cov_mno.rfc_date::VARCHAR last_updated,
          public.cov_mno.raster::VARCHAR,
          NULL::VARCHAR,
          round(public.cov_mno.dl_max /1000)::integer downloadKbitMax,
          round(public.cov_mno.ul_max /1000)::integer uploadKbitMax,
          round(public.cov_mno.dl_normal /1000)::integer downloadKbitNormal,
          round(public.cov_mno.ul_normal/1000)::integer uploadKbitNormal,
          ST_AsGeoJSON(ST_Transform(public.atraster.geom,4326)) geoJson,
                  ST_X(ST_Centroid(ST_Transform(public.atraster.geom,4326))),
          ST_Y(ST_Centroid(ST_Transform(public.atraster.geom,4326)))
          from public.atraster
          left join public.cov_mno on public.cov_mno.raster=public.atraster.id
          left join public.cov_visible_name vn on vn.operator = public.cov_mno.operator
          where public.cov_mno.raster is not null AND
                    ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint($1::FLOAT,$2::FLOAT),4326),3035)),public.atraster.geom);
END ;
$function$

